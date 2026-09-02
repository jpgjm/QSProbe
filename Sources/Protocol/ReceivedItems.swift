//
//  ReceivedItems.swift
//  QSProbe (M3)
//
//  受信するファイル / テキストの管理。
//
//  ファイルは `Documents/Received/` に**ストリーミング書き込み**する。
//  メモリに溜め込まない理由は iPad の jetsam 上限 (iPad 9 で約 1850 MiB) で、
//  大きな動画を受け取ると即座に殺されるため。`FileHandle` で逐次書く。
//

import Foundation
import SwiftProtobuf

/// 受信中のファイル 1 件。
final class ReceivingFile: Identifiable {

    let payloadId: Int64
    let name: String
    /// 相手が指定した相対ディレクトリ (フォルダ送信時)。
    let parentFolder: String
    let mimeType: String
    let totalSize: Int64
    let destinationURL: URL

    private(set) var receivedBytes: Int64 = 0
    private(set) var isComplete = false

    /// 受信後にどこへ収まったか。
    enum Destination {
        case files
        case photos
    }
    private(set) var destination: Destination = .files

    func markSavedToPhotos() {
        destination = .photos
    }

    private var handle: FileHandle?

    var id: Int64 { payloadId }

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(1.0, Double(receivedBytes) / Double(totalSize))
    }

    var displayPath: String {
        parentFolder.isEmpty ? name : "\(parentFolder)/\(name)"
    }

    init(
        payloadId: Int64,
        name: String,
        parentFolder: String,
        mimeType: String,
        totalSize: Int64,
        destinationURL: URL
    ) {
        self.payloadId = payloadId
        self.name = name
        self.parentFolder = parentFolder
        self.mimeType = mimeType
        self.totalSize = totalSize
        self.destinationURL = destinationURL
    }

    /// 受け入れ時に空ファイルを作って書き込みハンドルを開く。
    func open() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        manager.createFile(atPath: destinationURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: destinationURL)
    }

    /// チャンクを書き込む。offset が食い違っていたら nil ではなくエラーを投げる。
    func write(chunk: Data, at offset: Int64) throws {
        guard offset == receivedBytes else {
            throw ReceiveError.offsetMismatch(expected: receivedBytes, got: offset, name: name)
        }
        guard let handle else {
            throw ReceiveError.notOpened(name)
        }
        if !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
            receivedBytes += Int64(chunk.count)
        }
    }

    func finish() {
        try? handle?.close()
        handle = nil
        isComplete = true
    }

    func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: destinationURL)
    }
}

/// 受信したテキスト 1 件。
/// 受信したテキストの種別。
///
/// Quick Share の `TextMetadata.type` に対応する。stock は URL を送るとき
/// `.url` を立ててくるので、それを見て「開く」を出せる。
enum ReceivedTextKind {
    case text
    case url
    case address
    case phoneNumber
    case unknown

    init(_ raw: Sharing_Nearby_TextMetadata.TypeEnum) {
        switch raw {
        case .text: self = .text
        case .url: self = .url
        case .address: self = .address
        case .phoneNumber: self = .phoneNumber
        default: self = .unknown
        }
    }
}

struct ReceivedText: Identifiable {
    let id = UUID()
    let payloadId: Int64
    let title: String
    let body: String
    let kind: ReceivedTextKind

    /// ブラウザで開けるか。
    ///
    /// 相手が `.url` を立ててくるとは限らないため、`http(s)://` で始まる場合も
    /// 開けるものとして扱う。判定は本文の前後の空白を落としてから行う。
    var openableURL: URL? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let looksLikeURL = trimmed.lowercased().hasPrefix("http://")
            || trimmed.lowercased().hasPrefix("https://")
        guard kind == .url || looksLikeURL else { return nil }

        // 日本語を含む URL でも開けるようにエンコードしてから組み立てる
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed).union(.urlHostAllowed)
        ) else { return nil }
        return URL(string: encoded) ?? URL(string: trimmed)
    }
}

enum ReceiveError: Error, CustomStringConvertible {
    case offsetMismatch(expected: Int64, got: Int64, name: String)
    case notOpened(String)
    case unknownPayload(Int64)

    var description: String {
        switch self {
        case .offsetMismatch(let expected, let got, let name):
            return "\(name): チャンクの offset が不正 (期待 \(expected) / 実際 \(got))"
        case .notOpened(let name):
            return "\(name): 書き込みハンドルが開かれていません"
        case .unknownPayload(let id):
            return "未知の payload_id: \(id)"
        }
    }
}

/// 受信先ディレクトリの管理。
enum ReceiveDestination {

    /// `Documents/Received/`。「ファイル」App から取り出せる。
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 同名ファイルがあれば `名前 (1).ext` のように退避する。
    ///
    /// `parentFolder` が付いている場合は `Received/<parentFolder>/` の下に置く。
    /// 相手から来たパスなので、各要素を個別に検証して `..` を弾く。
    static func uniqueURL(for name: String, parentFolder: String = "") -> URL {
        let sanitized = sanitize(name)
        let baseDirectory = resolveDirectory(parentFolder: parentFolder)
        var candidate = baseDirectory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension()
        var counter = 1
        repeat {
            var path = "\(base.path) (\(counter))"
            if !ext.isEmpty { path += ".\(ext)" }
            candidate = URL(fileURLWithPath: path)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// `parentFolder` を安全に解決してディレクトリを作る。
    ///
    /// `..` を含む要素と絶対パス化を弾き、必ず `Received/` の下に収める。
    /// 空要素と `.` は落とすので、`a//b` や `/x` も内側に落ち着く。
    private static func resolveDirectory(parentFolder: String) -> URL {
        var directory = Self.directory
        guard !parentFolder.isEmpty else { return directory }

        let components = parentFolder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "." { continue }
            if trimmed == ".." {
                qlog(.warn, "受信: parent_folder に \"..\" が含まれていたため無視します")
                return Self.directory
            }
            directory = directory.appendingPathComponent(sanitize(trimmed), isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 相手から来たファイル名は信用しない。パス区切りなどを落とす。
    private static func sanitize(_ name: String) -> String {
        let trimmed = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "received-\(Int(Date().timeIntervalSince1970))" : trimmed
    }
}
