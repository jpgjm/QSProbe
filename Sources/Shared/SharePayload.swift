//
//  SharePayload.swift
//  QSProbe
//
//  Share Extension からホストアプリへ渡す受け渡し票。
//
//  ## 形
//
//  共有コンテナの `ShareInbox/` の下に、1 回の共有につき 1 つのフォルダを作る。
//
//      ShareInbox/
//        └ 20260901T061040-3F2A/
//            ├ payload.json          ← この構造体
//            ├ IMG_0001.HEIC
//            └ memo.txt
//
//  ファイル名は共有元が付けた名前をそのまま使う。衝突したら連番を足す。
//  実体とマニフェストを同じフォルダに閉じ込めるのは、取り込みに失敗した
//  ときにフォルダごと消せば後始末が終わるようにするため。
//
//  ## なぜ UserDefaults ではなくファイルなのか
//
//  AlterSend / LocalSend は共有 `UserDefaults` に一覧を書く実装だが、
//  こちらはファイルに寄せた。理由は 2 つ。
//
//  - 複数回続けて共有されたとき、`UserDefaults` の 1 キーだと上書きで
//    取りこぼす。フォルダを分ければ並ぶ。
//  - ホストが起動していない間に共有されたぶんも、起動時にフォルダを
//    走査するだけで拾える。取りこぼしの検知が要らない。
//

import Foundation

/// 受け渡し票 1 件。
struct SharePayload: Codable {

    struct Item: Codable {
        /// `ShareInbox/<id>/` からの相対名。
        let fileName: String
        /// 表示用の元の名前。`fileName` と同じことが多い。
        let displayName: String
        let byteCount: Int64
    }

    /// 作成時刻。古い置き去りを掃除する判断に使う。
    let createdAt: Date
    let items: [Item]

    static let manifestName = "payload.json"

    // MARK: - 書き出し

    /// `ShareInbox/` の下に新しいフォルダを作る。
    static func makeDropDirectory(in inbox: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"

        let stamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(4))
        let dir = inbox.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.manifestName))
    }

    // MARK: - 読み込み

    static func read(from directory: URL) -> SharePayload? {
        let url = directory.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharePayload.self, from: data)
    }

    /// 取り込み待ちのフォルダを古い順に返す。
    ///
    /// マニフェストがまだ書かれていないフォルダ (拡張が書いている最中) は
    /// 除く。書き終わってから初めて `payload.json` が現れるため、
    /// これだけで書き込み中との競合を避けられる。
    static func pendingDrops(in inbox: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        return entries
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return false }
                return manager.fileExists(
                    atPath: url.appendingPathComponent(manifestName).path
                )
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
