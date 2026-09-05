//
//  MachOEntitlements.swift
//  QSProbe
//
//  実行ファイルのコード署名に埋め込まれた entitlements を読む。
//
//  ## なぜ要るか
//
//  Share Extension が「共有シートには出るのに起動しない」という状態が
//  SideStore 署名でだけ続いている。ここまでで確認できた項目は全部正常。
//
//    - _CodeSignature あり
//    - CFBundlePackageType = XPC!
//    - NSExtensionPrincipalClass / NSExtensionPointIdentifier 正常
//    - ホストとバージョン一致
//    - プロファイルの application-identifier と bundleId 一致
//    - App Group もホストと一致
//
//  残っているのは **実際にバイナリへ焼き込まれた entitlements** だけ。
//  プロビジョニングプロファイルは「何を要求してよいか」の許可証であって、
//  署名時に実際に何が焼かれたかとは別物。ここが食い違うと AMFI が
//  プロセスの起動を拒み、何のログも残らずシートが閉じる。
//
//  Impactor は同じことを Rust でやっている (macho.rs の embedded_entitlements)。
//  こちらでも読めるようにして、両者を突き合わせる。
//
//  ## 読み方
//
//  Mach-O のロードコマンドから LC_CODE_SIGNATURE を探し、その先の
//  SuperBlob を辿って entitlements の blob を取り出す。
//
//      Mach-O header (32 bytes, リトルエンディアン)
//        └ load commands
//            └ LC_CODE_SIGNATURE (0x1D) → dataoff / datasize
//                  └ SuperBlob (ここから先はビッグエンディアン)
//                       magic 0xFADE0CC0, length, count
//                       └ index[count] = { type, offset }
//                             └ Entitlements blob
//                                  magic 0xFADE7171, length, XML plist
//
//  署名まわりの数値だけビッグエンディアンなので注意。
//

import Foundation

enum MachOEntitlements {

    // Mach-O
    private static let magic64: UInt32 = 0xFEED_FACF
    private static let magic64Swapped: UInt32 = 0xCFFA_EDFE
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let lcCodeSignature: UInt32 = 0x1D

    // コード署名
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    private static let entitlementsMagic: UInt32 = 0xFADE_7171
    private static let derEntitlementsMagic: UInt32 = 0xFADE_7172

    /// バンドルの実行ファイルから entitlements を読む。
    ///
    /// - Returns: 見つかれば plist、無ければ nil。
    static func read(bundle: URL) -> [String: Any]? {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let executableName = info["CFBundleExecutable"] as? String else {
            return nil
        }

        let executable = bundle.appendingPathComponent(executableName)
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else {
            return nil
        }

        guard let signature = codeSignatureRange(in: data) else { return nil }
        return entitlements(in: data, signatureRange: signature)
    }

    /// コード署名の CodeDirectory から素性を読む。
    ///
    /// `identifier` は**署名時に付けられる識別子**で、通常は bundle ID と
    /// 同じ文字列になる。ここが Info.plist の CFBundleIdentifier と食い違うと
    /// iOS はバンドルを拒む。再署名ツールが bundle ID を書き換えたのに
    /// 署名識別子を元のままにすると、この状態になる。
    struct CodeDirectoryInfo {
        let identifier: String
        let teamId: String?
        let flags: UInt32
        let version: UInt32
        let hashType: UInt8
        let hashSize: UInt8
        /// log2。12 なら 4 KB、14 なら 16 KB。
        let pageSizeLog2: UInt8
        let specialSlots: UInt32
        let codeSlots: UInt32
        /// version >= 0x20400 のときだけ入る。
        let execSegFlags: UInt64?

        var pageSize: Int { pageSizeLog2 == 0 ? 0 : 1 << Int(pageSizeLog2) }

        var hashName: String {
            switch hashType {
            case 1:  return "SHA-1"
            case 2:  return "SHA-256"
            case 3:  return "SHA-256(truncated)"
            case 4:  return "SHA-384"
            default: return "不明(\(hashType))"
            }
        }
    }

    static func codeDirectory(bundle: URL) -> CodeDirectoryInfo? {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let executableName = info["CFBundleExecutable"] as? String else {
            return nil
        }

        let executable = bundle.appendingPathComponent(executableName)
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let signature = codeSignatureRange(in: data) else {
            return nil
        }

        return codeDirectoryInfo(in: data, signatureRange: signature)
    }

    /// コード署名 SuperBlob に入っている blob を並べる。
    ///
    /// 署名の中身は複数の blob の集合で、種類が欠けると起動できないことがある。
    /// 特に iOS 15 以降は DER 形式の entitlements (0xFADE7172) を見る箇所が
    /// あり、XML 版しか無い署名は弾かれる場合がある。
    ///
    /// 実測で「同じ .app なのに署名ツールによって実行ファイルの大きさが
    /// 10 万バイト違う」ことが分かったので、何が入って何が入っていないかを
    /// 直接数える。
    static func signatureBlobs(bundle: URL)
        -> (total: Int, blobs: [(type: UInt32, magic: UInt32, length: Int)])? {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let executableName = info["CFBundleExecutable"] as? String else {
            return nil
        }

        let executable = bundle.appendingPathComponent(executableName)
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let range = codeSignatureRange(in: data) else {
            return nil
        }

        let base = range.lowerBound
        guard base + 12 <= data.count,
              readUInt32(data, at: base, bigEndian: true) == superBlobMagic else {
            return nil
        }

        let count = Int(readUInt32(data, at: base + 8, bigEndian: true))
        guard count > 0, count < 128 else { return nil }

        var blobs: [(UInt32, UInt32, Int)] = []
        for index in 0..<count {
            let entry = base + 12 + index * 8
            guard entry + 8 <= data.count else { break }

            let type = readUInt32(data, at: entry, bigEndian: true)
            let offset = base + Int(readUInt32(data, at: entry + 4, bigEndian: true))
            guard offset + 8 <= data.count else { continue }

            let magic = readUInt32(data, at: offset, bigEndian: true)
            let length = Int(readUInt32(data, at: offset + 4, bigEndian: true))
            blobs.append((type, magic, length))
        }

        return (range.count, blobs)
    }

    /// blob の種類に名前を付ける。
    static func blobName(type: UInt32, magic: UInt32) -> String {
        switch magic {
        case 0xFADE_0C02: return "CodeDirectory"
        case 0xFADE_0C01: return "Requirements"
        case 0xFADE_7171: return "Entitlements(XML)"
        case 0xFADE_7172: return "Entitlements(DER)"
        case 0xFADE_0B01: return "CMS署名"
        default:          return "不明(0x" + String(magic, radix: 16) + ")"
        }
    }

    // MARK: - Mach-O

    /// LC_CODE_SIGNATURE が指す範囲を探す。
    private static func codeSignatureRange(in data: Data) -> Range<Int>? {
        guard data.count > 32 else { return nil }

        let magic = readUInt32(data, at: 0, bigEndian: false)

        // Universal binary は先頭のアーキテクチャだけ見る。
        // 実機向けの成果物は普通 arm64 単体だが、念のため。
        if magic == fatMagic {
            let count = Int(readUInt32(data, at: 4, bigEndian: true))
            guard count > 0 else { return nil }
            let offset = Int(readUInt32(data, at: 8 + 8, bigEndian: true))
            guard offset < data.count else { return nil }
            let slice = data.subdata(in: offset..<data.count)
            guard let range = codeSignatureRange(in: slice) else { return nil }
            return (range.lowerBound + offset)..<(range.upperBound + offset)
        }

        guard magic == magic64 || magic == magic64Swapped else { return nil }

        let commandCount = Int(readUInt32(data, at: 16, bigEndian: false))
        var cursor = 32

        for _ in 0..<commandCount {
            guard cursor + 8 <= data.count else { return nil }

            let command = readUInt32(data, at: cursor, bigEndian: false)
            let size = Int(readUInt32(data, at: cursor + 4, bigEndian: false))
            guard size >= 8 else { return nil }

            if command == lcCodeSignature, cursor + 16 <= data.count {
                let offset = Int(readUInt32(data, at: cursor + 8, bigEndian: false))
                let length = Int(readUInt32(data, at: cursor + 12, bigEndian: false))
                guard offset + length <= data.count else { return nil }
                return offset..<(offset + length)
            }

            cursor += size
        }

        return nil
    }

    // MARK: - コード署名

    /// SuperBlob を辿って entitlements の plist を取り出す。
    private static func entitlements(in data: Data, signatureRange: Range<Int>) -> [String: Any]? {
        let base = signatureRange.lowerBound
        guard base + 12 <= data.count else { return nil }
        guard readUInt32(data, at: base, bigEndian: true) == superBlobMagic else { return nil }

        let count = Int(readUInt32(data, at: base + 8, bigEndian: true))
        guard count > 0, count < 128 else { return nil }

        for index in 0..<count {
            let entry = base + 12 + index * 8
            guard entry + 8 <= data.count else { return nil }

            let offset = base + Int(readUInt32(data, at: entry + 4, bigEndian: true))
            guard offset + 8 <= data.count else { continue }

            let magic = readUInt32(data, at: offset, bigEndian: true)
            guard magic == entitlementsMagic || magic == derEntitlementsMagic else { continue }
            // DER 版は plist ではないので読み飛ばす。XML 版だけ使う。
            guard magic == entitlementsMagic else { continue }

            let length = Int(readUInt32(data, at: offset + 4, bigEndian: true))
            guard length > 8, offset + length <= data.count else { continue }

            let payload = data.subdata(in: (offset + 8)..<(offset + length))
            return try? PropertyListSerialization.propertyList(
                from: payload, options: [], format: nil
            ) as? [String: Any]
        }

        return nil
    }

    /// SuperBlob から最初の CodeDirectory を読む。
    private static func codeDirectoryInfo(
        in data: Data, signatureRange: Range<Int>
    ) -> CodeDirectoryInfo? {
        let base = signatureRange.lowerBound
        guard base + 12 <= data.count,
              readUInt32(data, at: base, bigEndian: true) == superBlobMagic else {
            return nil
        }

        let count = Int(readUInt32(data, at: base + 8, bigEndian: true))
        guard count > 0, count < 128 else { return nil }

        for index in 0..<count {
            let entry = base + 12 + index * 8
            guard entry + 8 <= data.count else { return nil }

            let offset = base + Int(readUInt32(data, at: entry + 4, bigEndian: true))
            guard offset + 44 <= data.count,
                  readUInt32(data, at: offset, bigEndian: true) == codeDirectoryMagic else {
                continue
            }

            let version = readUInt32(data, at: offset + 8, bigEndian: true)
            let flags = readUInt32(data, at: offset + 12, bigEndian: true)
            let identOffset = Int(readUInt32(data, at: offset + 20, bigEndian: true))
            let specialSlots = readUInt32(data, at: offset + 24, bigEndian: true)
            let codeSlots = readUInt32(data, at: offset + 28, bigEndian: true)
            let hashSize = data[data.startIndex + offset + 36]
            let hashType = data[data.startIndex + offset + 37]
            let pageSizeLog2 = data[data.startIndex + offset + 39]

            guard let identifier = cString(data, at: offset + identOffset) else { continue }

            // teamOffset は version 0x20200 以降にだけある。
            var teamId: String?
            if version >= 0x2_0200 {
                let teamOffset = Int(readUInt32(data, at: offset + 48, bigEndian: true))
                if teamOffset > 0 {
                    teamId = cString(data, at: offset + teamOffset)
                }
            }

            // execSegFlags は version 0x20400 以降。
            // CS_EXECSEG_MAIN_BINARY (0x1) が主実行ファイルの印。
            var execSegFlags: UInt64?
            if version >= 0x2_0400, offset + 88 <= data.count {
                let high = UInt64(readUInt32(data, at: offset + 80, bigEndian: true))
                let low = UInt64(readUInt32(data, at: offset + 84, bigEndian: true))
                execSegFlags = (high << 32) | low
            }

            return CodeDirectoryInfo(
                identifier: identifier,
                teamId: teamId,
                flags: flags,
                version: version,
                hashType: hashType,
                hashSize: hashSize,
                pageSizeLog2: pageSizeLog2,
                specialSlots: specialSlots,
                codeSlots: codeSlots,
                execSegFlags: execSegFlags
            )
        }

        return nil
    }

    /// NUL 終端の文字列を読む。
    private static func cString(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var bytes: [UInt8] = []
        var cursor = offset
        while cursor < data.count, data[data.startIndex + cursor] != 0 {
            bytes.append(data[data.startIndex + cursor])
            cursor += 1
            if bytes.count > 512 { return nil }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - 読み取り

    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + byte])
        }
        return bigEndian ? value : value.byteSwapped
    }
}
