//
//  OutgoingItems.swift
//  QSProbe (M5)
//
//  送信するファイルのモデルと、選択元ごとの前処理。
//
//  選択元は 3 系統ある。
//    1. ファイル App から単体ファイル   → セキュリティスコープを保持して直接読む
//    2. ファイル App からフォルダ       → 再帰列挙し、相対パスを parent_folder に載せる
//    3. 写真 App から写真・動画         → PHPicker が一時 URL をくれるので Outbox へコピー
//
//  いずれもメモリには載せず `FileHandle` で 512 KiB ずつ読む。
//

import Foundation
import UniformTypeIdentifiers
import SwiftProtobuf

/// セキュリティスコープ付き URL の寿命管理。
///
/// フォルダを選んだ場合、**フォルダ自身のスコープが開いている間だけ**
/// 配下のファイルを読める。子ファイルごとに開くのではなく、この 1 個を
/// 送信完了まで生かしておく必要がある。ARC に任せるためクラスにしてある。
final class SecurityScope {
    private let url: URL
    private let active: Bool

    init(url: URL) {
        self.url = url
        self.active = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if active {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// 送信候補 1 件。UI 上で保持し、送信開始時に `OutgoingFile` へ変換する。
struct PendingItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    /// Quick Share の `parent_folder`。トップレベルなら空文字。
    let parentFolder: String
    /// Outbox にコピーした一時ファイルか (送信後に削除する)。
    let isTemporary: Bool
    /// フォルダ選択時に共有するスコープ。
    let scope: SecurityScope?

    var displayPath: String {
        parentFolder.isEmpty ? url.lastPathComponent : "\(parentFolder)/\(url.lastPathComponent)"
    }

    static func == (lhs: PendingItem, rhs: PendingItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 送信中のファイル 1 件。
final class OutgoingFile: Identifiable {

    let url: URL
    let name: String
    let parentFolder: String
    let mimeType: String
    let fileType: Sharing_Nearby_FileMetadata.TypeEnum
    let totalSize: Int64
    let payloadId: Int64
    let metadataId: Int64

    private(set) var sentBytes: Int64 = 0
    private(set) var isComplete = false

    private let isTemporary: Bool
    private let scope: SecurityScope?
    private var handle: FileHandle?

    var id: Int64 { payloadId }

    var displayPath: String {
        parentFolder.isEmpty ? name : "\(parentFolder)/\(name)"
    }

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(1.0, Double(sentBytes) / Double(totalSize))
    }

    init?(item: PendingItem) {
        let url = item.url

        // ディレクトリやパッケージ (Live Photo の `.pvt` など) は単一ファイルとして
        // 送れない。`attributesOfItem` はディレクトリでもサイズを返してしまうので、
        // ここで明示的に弾く。M5 でこれが無く、実体のない項目がキューに入っていた。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            qlog(.warn, "送信: \(url.lastPathComponent) はディレクトリのため送れません")
            return nil
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }

        self.url = url
        self.name = OutgoingFile.sanitize(url.lastPathComponent)
        self.parentFolder = item.parentFolder
        self.totalSize = size
        self.payloadId = Int64.random(in: Int64.min...Int64.max)
        self.metadataId = Int64.random(in: Int64.min...Int64.max)
        self.isTemporary = item.isTemporary
        self.scope = item.scope

        let mime = OutgoingFile.mimeType(for: url)
        self.mimeType = mime
        self.fileType = OutgoingFile.fileType(mimeType: mime, url: url)
    }

    func open() throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    /// 次のチャンクを読む。ファイル終端なら空 Data が返る。
    func readChunk(maxBytes: Int) throws -> Data {
        guard let handle else { return Data() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        sentBytes += Int64(data.count)
        return data
    }

    func finish() {
        try? handle?.close()
        handle = nil
        isComplete = true
        cleanUpTemporary()
    }

    func abort() {
        try? handle?.close()
        handle = nil
        cleanUpTemporary()
    }

    private func cleanUpTemporary() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - ヘルパー

    private static func sanitize(_ name: String) -> String {
        let trimmed = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "file" : trimmed
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func fileType(
        mimeType: String,
        url: URL
    ) -> Sharing_Nearby_FileMetadata.TypeEnum {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        if url.pathExtension.lowercased() == "apk" { return .androidApp }
        if mimeType.hasPrefix("text/") || mimeType == "application/pdf" { return .document }
        return .unknown
    }
}

// MARK: - フォルダの再帰列挙

enum FolderScanner {

    /// 深すぎるツリーで固まらないための保険。Bada と同じ値。
    static let maxDepth = 32

    /// 選んだフォルダ配下のファイルを列挙する。
    ///
    /// `parent_folder` の規約は Bada の `DocumentTreeFileSourceFactory` に合わせられる。
    /// - `includeRootName == false`: `Trip/photos/sunset.jpg` → `parent_folder = "photos"`
    ///   (選んだフォルダ自身の名前は含めない。受信側が選んだ保存先の直下に展開される)
    /// - `includeRootName == true`: → `parent_folder = "Trip/photos"`
    ///   (フォルダ名ごと復元される。ユーザーの直感に近い)
    ///
    /// どちらが stock 実装と噛み合うかは実機で確かめる価値があるため、切り替え可能にしてある。
    static func scan(folder: URL, includeRootName: Bool) -> [PendingItem] {
        // フォルダ自身のスコープを 1 個だけ開き、配下のファイル全部で共有する。
        let scope = SecurityScope(url: folder)

        var results: [PendingItem] = []
        var coordinationError: NSError?

        NSFileCoordinator().coordinate(readingItemAt: folder, error: &coordinationError) { coordinated in
            let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
            guard let enumerator = FileManager.default.enumerator(
                at: coordinated,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }

            let rootPrefix = includeRootName ? folder.lastPathComponent : ""
            let basePath = coordinated.standardizedFileURL.path

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      let isDirectory = values.isDirectory else { continue }
                if isDirectory {
                    if enumerator.level > maxDepth { enumerator.skipDescendants() }
                    continue
                }

                let relative = relativeDirectory(of: fileURL, basePath: basePath)
                let parent: String
                if rootPrefix.isEmpty {
                    parent = relative
                } else if relative.isEmpty {
                    parent = rootPrefix
                } else {
                    parent = "\(rootPrefix)/\(relative)"
                }

                results.append(PendingItem(
                    url: fileURL,
                    parentFolder: parent,
                    isTemporary: false,
                    scope: scope
                ))
            }
        }

        if let coordinationError {
            qlog(.warn, "FolderScanner: 読み取り調整に失敗 — \(coordinationError)")
        }
        // トップレベルのファイルを先に、次に深い階層。stock Android の並びに合わせる。
        return results.sorted {
            ($0.parentFolder, $0.url.lastPathComponent) < ($1.parentFolder, $1.url.lastPathComponent)
        }
    }

    /// `basePath` から見た、ファイルが属するディレクトリの相対パス。
    private static func relativeDirectory(of fileURL: URL, basePath: String) -> String {
        let directory = fileURL.standardizedFileURL.deletingLastPathComponent().path
        guard directory.hasPrefix(basePath) else { return "" }
        var relative = String(directory.dropFirst(basePath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}

// MARK: - 一時ファイル置き場

/// 写真 App から取り出したファイルを一旦置く場所。
enum Outbox {

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QSProbeOutbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 衝突しない URL を作る。
    static func uniqueURL(for name: String) -> URL {
        let base = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension()
        var counter = 2
        var candidate = base
        repeat {
            var path = "\(stem.path)-\(counter)"
            if !ext.isEmpty { path += ".\(ext)" }
            candidate = URL(fileURLWithPath: path)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// 起動時と送信開始前に掃除する。前回の残骸でディスクを食わないため。
    static func purge() {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? manager.removeItem(at: url)
        }
    }
}
