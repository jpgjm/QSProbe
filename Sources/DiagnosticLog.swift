//
//  DiagnosticLog.swift
//  QSProbe
//
//  Mac も Web Inspector も使えない環境での切り分け用。
//  画面に出しつつ、`Documents/Log/` にも書き出す。
//
//  ## 書き出しは JSON Lines (NDJSON)
//
//  1 行 1 オブジェクトで、行単位に完結しています。
//
//  ```json
//  {"ts":"2026-08-12T20:11:41.123+09:00","level":"OK","category":"Advertiser","message":"★ mDNS publish 成功"}
//  ```
//
//  この形式を選んだ理由:
//
//  - **途中で切れても壊れない。** 配列で包む JSON だと、クラッシュや強制終了で
//    末尾の `]` が書かれず、ファイル全体が読めなくなります。NDJSON なら
//    最後の 1 行を捨てるだけで残りは使えます。追記も 1 行足すだけです。
//  - **grep がそのまま効く。** 1 行に必要な情報が揃っているので、
//    `grep Outbound` のような素朴な絞り込みが従来どおり使えます。
//  - **集計しやすい。** `category` と `level` が独立した項目になるので、
//    「Session の WARN だけ」「keepAlive の間隔」といった抽出が
//    正規表現に頼らず書けます。
//
//  `category` は `"Advertiser: ..."` のような接頭辞から機械的に切り出しています。
//  接頭辞が無い行は `App` になります。
//
//  ## 画面表示はテキストのまま
//
//  読むのは人間なので、画面表示は `[HH:mm:ss.SSS] LEVEL message` のままです。
//  JSON は機械が読むファイル側だけです。
//
//  ## 共有は zip 1 個
//
//  人が読む `.txt` と機械が読む `.jsonl` の両方を、同じ内容から作って
//  1 個の zip にまとめます。どちらを渡すか迷わずに済みます。
//
//  ```
//  2026-08-13T04-27-50+09-00_log.zip
//    ├─ 2026-08-13T04-27-50+09-00_log.txt
//    └─ 2026-08-13T04-27-50+09-00_log.jsonl
//  ```
//
//  zip 化は `NSFileCoordinator` の `.forUploading` を使っています。
//  ディレクトリを渡すと zip にまとめた一時ファイルを作ってくれるので、
//  外部ライブラリを足さずに済みます。
//
//  ## ファイル名
//
//  `2026-08-12T20-11-41+09-00_log.jsonl` のように、ISO 8601 のコロンを
//  ハイフンに置き換えた時刻を先頭に付けます。ファイル名にコロンは使えません。
//  共有時もこの名前が付くよう、文字列ではなく**ファイル URL を渡します**
//  (文字列を共有すると iOS が勝手に「テキスト.txt」と名付けます)。
//

import Foundation
import Combine

enum LogLevel: String {
    case info = "INFO"
    case ok   = "OK  "
    case warn = "WARN"
    case error = "ERR "

    /// JSON に入れる、空白を含まない表記。
    var token: String {
        rawValue.trimmingCharacters(in: .whitespaces)
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    /// 画面と、テキスト共有で使う表記。
    var formatted: String {
        "[\(LogEntry.displayFormatter.string(from: timestamp))] \(level.rawValue) \(message)"
    }

    /// `"Advertiser: ..."` のような接頭辞を切り出す。無ければ `App`。
    var category: String {
        guard let colon = message.firstIndex(of: ":") else { return "App" }
        let head = String(message[message.startIndex..<colon])
        guard !head.isEmpty, head.count <= 24,
              head.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "App"
        }
        return head
    }

    /// 接頭辞を取り除いた本文。
    var body: String {
        guard category != "App",
              let colon = message.firstIndex(of: ":") else { return message }
        return String(message[message.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// NDJSON の 1 行。
private struct LogRecord: Encodable {
    let ts: String
    let level: String
    let category: String
    let message: String
}

final class DiagnosticLog: ObservableObject {

    static let shared = DiagnosticLog()

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 500
    private let fileQueue = DispatchQueue(label: "qsprobe.log.file")
    private let encoder = JSONEncoder()

    /// 書き出し先。起動ごとに 1 本。
    private(set) var logFileURL: URL?

    private init() {
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            logFileURL = nil
            return
        }
        let directory = documents.appendingPathComponent("Log", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logFileURL = directory.appendingPathComponent(
            "\(DiagnosticLog.fileStamp(Date()))_log.jsonl"
        )
    }

    // MARK: - 記録

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        appendToFile(entry)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    /// 画面と書き出しファイルの両方を空にする。
    ///
    /// 画面だけ消してファイルが残っていると、「消したはずのものが共有した zip に
    /// 入っている」という食い違いが起きるため、両方を対象にする。
    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
        fileQueue.async {
            guard let url = self.logFileURL else { return }
            try? Data().write(to: url, options: .atomic)
        }
    }

    /// 画面に出ている分をテキストにまとめたもの。
    var fullText: String {
        entries.map { $0.formatted }.joined(separator: "\n")
    }

    // MARK: - 共有

    /// `.txt` と `.jsonl` を 1 個の zip にまとめて返す。
    ///
    /// どちらも**同じ内容**で、書き出しファイル (全期間) から作る。
    /// 画面のバッファは 500 件で頭が落ちるので、そちらは使わない。
    ///
    /// 文字列のまま共有シートに渡すと iOS が「テキスト.txt」と名付けてしまうため、
    /// 必ずファイル URL を渡すこと。
    func logArchiveForSharing() -> URL? {
        let stamp = DiagnosticLog.fileStamp(Date())
        let baseName = "\(stamp)_log"

        let manager = FileManager.default
        let workRoot = manager.temporaryDirectory
            .appendingPathComponent("QSProbeLogExport", isDirectory: true)
        let folder = workRoot.appendingPathComponent(baseName, isDirectory: true)

        // 前回の残骸を消してから作り直す
        try? manager.removeItem(at: workRoot)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("[QSProbe] 書き出し用ディレクトリを作れません: \(error)")
            return nil
        }

        // ファイルへの書き込みが終わるのを待ってから読む
        fileQueue.sync {}

        let jsonlSource = logFileURL
        let jsonlData = jsonlSource.flatMap { try? Data(contentsOf: $0) } ?? Data()

        do {
            try jsonlData.write(to: folder.appendingPathComponent("\(baseName).jsonl"))
            let text = DiagnosticLog.textFromJsonl(jsonlData, fallback: fullText)
            try Data(text.utf8).write(to: folder.appendingPathComponent("\(baseName).txt"))
        } catch {
            print("[QSProbe] ログの書き出しに失敗: \(error)")
            return nil
        }

        return DiagnosticLog.zipDirectory(folder, named: "\(baseName).zip")
    }

    /// ディレクトリを zip にまとめる。外部ライブラリは使わない。
    ///
    /// `NSFileCoordinator` の `.forUploading` はディレクトリを zip にした
    /// 一時ファイルの URL をブロック内で渡してくる。ブロックを抜けると消えるので、
    /// **その場で自分の管理下へコピーする**必要がある。
    private static func zipDirectory(_ directory: URL, named name: String) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinationError
        ) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            print("[QSProbe] zip 化に失敗: \(coordinationError)")
            return nil
        }
        if let copyError {
            print("[QSProbe] zip のコピーに失敗: \(copyError)")
            return nil
        }
        return destination
    }

    /// JSON Lines を、画面と同じ体裁のテキストへ戻す。
    ///
    /// 時刻は `ts` の該当部分をそのまま切り出す。文字列から `Date` を作り直して
    /// また整形するより速く、ずれる余地もない。
    static func textFromJsonl(_ data: Data, fallback: String) -> String {
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else { return fallback }

        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(DecodedRecord.self, from: lineData) else {
                continue
            }
            // "2026-08-13T04:27:50.123+09:00" の時刻部分だけを取る
            let time = record.ts.count >= 23
                ? String(record.ts.dropFirst(11).prefix(12))
                : record.ts
            let level = record.level.padding(toLength: 4, withPad: " ", startingAt: 0)
            let message = record.category == "App"
                ? record.message
                : "\(record.category): \(record.message)"
            lines.append("[\(time)] \(level) \(message)")
        }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
    }

    private struct DecodedRecord: Decodable {
        let ts: String
        let level: String
        let category: String
        let message: String
    }

    // MARK: - 内部

    private func appendToFile(_ entry: LogEntry) {
        guard let url = logFileURL else { return }
        let record = LogRecord(
            ts: DiagnosticLog.isoFormatter.string(from: entry.timestamp),
            level: entry.level.token,
            category: entry.category,
            message: entry.body
        )
        guard let json = try? encoder.encode(record) else { return }

        fileQueue.async {
            var line = json
            line.append(0x0A)  // 改行
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// ファイル名に使う時刻。`2026-08-12T20-11-41+09-00`
    /// ISO 8601 のコロンはファイル名に使えないのでハイフンにする。
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// ログ 1 行の時刻。ミリ秒とタイムゾーンつきの ISO 8601。
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}

/// どこからでも呼べる短縮形。
func qlog(_ level: LogLevel, _ message: String) {
    DiagnosticLog.shared.log(level, message)
    print("[QSProbe] \(level.rawValue) \(message)")
}
