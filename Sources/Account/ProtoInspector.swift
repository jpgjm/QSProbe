//
//  ProtoInspector.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  protobuf のバイト列を、定義を持たないまま「フィールド番号・型・長さ」に
//  ばらすための道具。
//
//  ## なぜ要るのか
//
//  `SharedCredential.data` を Bada の `wire_format.proto` の
//  `PublicCertificate` として読んだところ、フィールド 1〜3 は筋の通る値
//  (32 / 32 / 91 バイト) になった。ところが `data` 全体は 394〜1037 バイトで、
//  読めた合計は 180 バイト程度にしかならない。**残りが見えていない。**
//
//  推測で定義を足していくと、当たったのか偶然かの区別がつかなくなる。
//  先に「何番のフィールドが何バイトあるか」を機械的に出して、
//  そこから定義を書く。
//
//  ## 分かること・分からないこと
//
//  ワイヤ形式から取れるのはフィールド番号とワイヤ型だけで、
//  意味 (int32 か enum か、bytes か string か入れ子か) は分からない。
//  そこは中身を見て推測する。printable な ASCII が続けば文字列、
//  先頭が妥当なタグに見えれば入れ子、という程度の手掛かりは出す。
//

import Foundation

enum ProtoInspector {

    struct Field {
        let number: Int
        let wireType: Int
        /// 可変長整数の値 (ワイヤ型 0 のとき)。
        let varint: UInt64?
        /// 長さ付きフィールドの中身 (ワイヤ型 2 のとき)。
        let payload: Data?

        var wireTypeName: String {
            switch wireType {
            case 0: return "varint"
            case 1: return "64bit"
            case 2: return "bytes"
            case 5: return "32bit"
            default: return "型\(wireType)"
            }
        }
    }

    /// バイト列をフィールドに分解する。壊れていたら、そこまでを返す。
    static func fields(in data: Data) -> [Field] {
        var out: [Field] = []
        let bytes = [UInt8](data)
        var index = 0

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let tag = readVarint() else { break }
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard number > 0 else { break }

            switch wireType {
            case 0:
                guard let value = readVarint() else { return out }
                out.append(Field(number: number, wireType: 0, varint: value, payload: nil))
            case 1:
                guard index + 8 <= bytes.count else { return out }
                index += 8
                out.append(Field(number: number, wireType: 1, varint: nil, payload: nil))
            case 2:
                guard let length = readVarint() else { return out }
                let end = index + Int(length)
                guard end <= bytes.count else { return out }
                let payload = Data(bytes[index..<end])
                index = end
                out.append(Field(number: number, wireType: 2, varint: nil, payload: payload))
            case 5:
                guard index + 4 <= bytes.count else { return out }
                index += 4
                out.append(Field(number: number, wireType: 5, varint: nil, payload: nil))
            default:
                // 未知のワイヤ型。ここから先は読めない。
                return out
            }
        }
        return out
    }

    /// 1 フィールドを 1 行で説明する。
    static func describe(_ field: Field) -> String {
        var text = "  f\(field.number) [\(field.wireTypeName)]"

        if let varint = field.varint {
            text += " = \(varint)"
            // ミリ秒エポックに見えるなら日時も添える。2001〜2100 年あたり。
            if varint > 978_000_000_000, varint < 4_100_000_000_000 {
                let date = Date(timeIntervalSince1970: TimeInterval(varint) / 1000)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/MM/dd HH:mm"
                text += " (\(formatter.string(from: date)))"
            }
            return text
        }

        guard let payload = field.payload else { return text }
        text += " \(payload.count) バイト"

        if let string = printableString(payload) {
            text += " = \"\(string)\""
        } else if looksLikeMessage(payload) {
            let inner = fields(in: payload)
            let numbers = inner.map { "f\($0.number)" }.joined(separator: ",")
            text += " (入れ子か: \(numbers))"
        } else {
            text += " = \(hex(payload, limit: 12))"
        }
        return text
    }

    /// 全体を複数行で説明する。
    static func describe(_ data: Data) -> [String] {
        let parsed = fields(in: data)
        var lines = ["\(data.count) バイト / \(parsed.count) フィールド"]
        lines.append(contentsOf: parsed.map(describe))

        // 読めた分の合計と実長がずれていたら、その旨を出す。
        let consumed = parsed.reduce(0) { partial, field in
            partial + (field.payload?.count ?? 0)
        }
        if consumed < data.count / 2 {
            lines.append("  ※ 読めた中身が全体の半分未満です。壊れている可能性")
        }
        return lines
    }

    // MARK: - 見分け

    private static func printableString(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 120 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 制御文字が混ざっていたら文字列ではないとみなす。
        let printable = text.unicodeScalars.allSatisfy {
            $0 == " " || ($0.value >= 0x21 && $0.value != 0x7F)
        }
        return printable ? text : nil
    }

    /// 先頭がフィールド 1〜30 の妥当なタグに見えるか。
    private static func looksLikeMessage(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let number = Int(first >> 3)
        let wireType = Int(first & 0x07)
        guard number >= 1, number <= 30 else { return false }
        guard [0, 1, 2, 5].contains(wireType) else { return false }
        // 中身を実際にばらしてみて、最後まで読み切れるかで判断する。
        let inner = fields(in: data)
        return inner.count >= 1 && inner.count <= 30
    }

    static func hex(_ data: Data, limit: Int? = nil) -> String {
        let slice = limit.map { data.prefix($0) } ?? data.prefix(data.count)
        let text = slice.map { String(format: "%02x", $0) }.joined()
        if let limit, data.count > limit { return text + "…" }
        return text
    }
}
