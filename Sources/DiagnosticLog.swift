//
//  DiagnosticLog.swift
//  QSProbe
//
//  Mac も Web Inspector も使えない環境での切り分け用。
//  画面上に出しつつ、`Documents/Log/` にも書き出す。
//  「ファイル」App から QSProbe フォルダを開けば中身を確認できる
//  (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` を有効化済み)。
//
//  注意: あえて `@MainActor` を付けず、内部で明示的に main へ dispatch している。
//  Swift の actor 分離とデリゲートコールバックの組み合わせで警告が増えるのを
//  避けるため。
//

import Foundation
import Combine

enum LogLevel: String {
    case info = "INFO"
    case ok   = "OK  "
    case warn = "WARN"
    case error = "ERR "
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    var formatted: String {
        "[\(LogEntry.formatter.string(from: timestamp))] \(level.rawValue) \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

final class DiagnosticLog: ObservableObject {

    static let shared = DiagnosticLog()

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 500
    private let fileQueue = DispatchQueue(label: "qsprobe.log.file")
    private let logFileURL: URL?

    private init() {
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            let dir = docs.appendingPathComponent("Log", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            logFileURL = dir.appendingPathComponent("qsprobe-\(f.string(from: Date())).log")
        } else {
            logFileURL = nil
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        writeToFile(entry.formatted)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    /// 共有シート用に、現在の全ログを一つのテキストにまとめる。
    var fullText: String {
        entries.map { $0.formatted }.joined(separator: "\n")
    }

    private func writeToFile(_ line: String) {
        guard let url = logFileURL else { return }
        fileQueue.async {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// どこからでも呼べる短縮形。
func qlog(_ level: LogLevel, _ message: String) {
    DiagnosticLog.shared.log(level, message)
    print("[QSProbe] \(level.rawValue) \(message)")
}
