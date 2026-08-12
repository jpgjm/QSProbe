//
//  Base64Url.swift
//  QSProbe
//
//  Bada の `core-protocol/.../endpoint/Base64Url.kt` に対応。
//  Quick Share は mDNS のインスタンス名と TXT レコード `n=` の双方で
//  「URL-safe base64・パディング無し」を使う。
//

import Foundation

enum Base64Url {

    /// URL-safe base64 (パディング無し) にエンコードする。
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// URL-safe base64 をデコードする。不正な入力では nil を返す (throw しない)。
    static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // パディングを復元する
        let remainder = s.count % 4
        if remainder == 2 { s += "==" }
        else if remainder == 3 { s += "=" }
        else if remainder == 1 { return nil }
        return Data(base64Encoded: s)
    }
}
