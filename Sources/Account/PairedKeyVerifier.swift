//
//  PairedKeyVerifier.swift
//  QSProbe — 実験機能 / アカウント連携 (第4段)
//
//  相手が `PAIRED_KEY_ENCRYPTION` に載せてくる `signed_data` を、
//  証明書の公開鍵で検証する。
//
//  ## `secret_id_hash` を追うのをやめた理由
//
//  広告からの特定で、**相手の証明書が手元にあること**が確定した。
//  それでも `secret_id_hash` は 122 通り × 43 件のどれとも一致しない。
//
//  ここで `signed_data` を見ると 71 バイトで、先頭が `3045…` や `3044…`。
//  これは **DER 形式の ECDSA 署名**。つまり相手は認証トークンに
//  秘密鍵で署名して送ってきている。
//
//  証明書には `public_key` (91 バイトの SubjectPublicKeyInfo) が入っている。
//  **署名を検証できれば、相手が本人であることが直接証明できる。**
//  ハッシュの一致は「同じ鍵を持っている」ことの弱い証拠でしかないので、
//  こちらのほうが本筋。
//
//  Windows 版のログ文字列とも整合する。
//
//  ```
//  Successfully verified remote paired key encryption frame.
//  Unable to verify remote paired key encryption frame.
//  ```
//
//  ## 署名の対象が分からない
//
//  何に署名しているかは文字列からは読めない。UKEY2 の authString そのものか、
//  その先頭を切ったものか、ハッシュ済みか。**検証は正誤がはっきりする**ので、
//  候補を並べて総当たりしてよい。当たったものが答えになる。
//

import Foundation
import CryptoKit

/// 覚えた印を保持するため、メインアクターに置く。
/// 呼び出し元 (`InboundSession` / `OutboundSession`) はどちらもメインアクター。
@MainActor
enum PairedKeyVerifier {

    /// 検証できた場合、どの組み合わせで通ったかを返す。
    static func verify(
        signature: Data, publicKeySPKI: Data, authToken: Data
    ) -> String? {
        guard !signature.isEmpty, !publicKeySPKI.isEmpty, !authToken.isEmpty else {
            return nil
        }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKeySPKI) else {
            return nil
        }

        // 署名は DER のはず。念のため raw (r||s 64 バイト) も見る。
        var signatures: [(String, P256.Signing.ECDSASignature)] = []
        if let der = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            signatures.append(("der", der))
        }
        if signature.count == 64,
           let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            signatures.append(("raw", raw))
        }
        guard !signatures.isEmpty else { return nil }

        // 署名対象の候補。CryptoKit は `for:` にデータを渡すと内部で
        // SHA-256 をかけるので、「素のトークン」と「ハッシュ済み」を分けて試す。
        //
        // 実測で確定した形を先頭に置く。
        //
        //   payload   = 0x01 || authString(32 バイト)
        //   signature = DER の ECDSA (P-256, SHA-256)
        //
        // 先頭の 0x01 は役割を表す印。送信側と受信側が同じ値に署名すると
        // 片方の署名をそのまま返せてしまうため、それを避けるためのもの。
        var messages: [(String, Data)] = [
            ("0x01+t\(authToken.count)", Data([0x01]) + authToken),
            ("t\(authToken.count)", authToken),
        ]
        for length in [5, 4, 6, 16] where authToken.count > length {
            messages.append(("t\(length)", Data(authToken.prefix(length))))
        }

        for (signatureName, parsed) in signatures {
            for (messageName, message) in messages {
                // ① データとして渡す (内部で SHA-256)
                if key.isValidSignature(parsed, for: message) {
                    return "\(signatureName)/\(messageName)"
                }
                // ② 既にハッシュ済みとして渡す
                let digest = SHA256.hash(data: message)
                if key.isValidSignature(parsed, for: digest) {
                    return "\(signatureName)/sha256(\(messageName))"
                }
            }
        }

        // 素のトークンで通らないなら、前後に 1 バイト付いている線を疑う。
        //
        // Nearby は送信側と受信側で違う印を付けてから署名する作りになっている
        // はず。同じ値に両者が署名すると、片方の署名をそのまま返せてしまう
        // (反射攻撃) ため。印が 1 バイトなら 256 通りしかないので、
        // 総当たりで特定できる。検証は正誤がはっきりするので誤判定もしない。
        // 一度当たった印は覚えておき、次からは真っ先に試す。
        // 役割ごとに違う値のはずなので、複数を覚える。
        for byte in learnedPrefixes {
            for (signatureName, parsed) in signatures {
                if key.isValidSignature(parsed, for: Data([byte]) + authToken) {
                    return "\(signatureName)/前置き 0x\(hex(byte))"
                }
            }
        }

        // トークンの長さも確定していないので、全体と先頭 5 バイトを見る。
        // Nearby Connections が認証トークンに使う長さは実装依存で、
        // HKDF-Expand の出力は前方一致するため「先頭を切る」で再現できる。
        let baseTokens: [(String, Data)] = [
            ("t\(authToken.count)", authToken),
            ("t5", Data(authToken.prefix(5))),
        ]

        for (signatureName, parsed) in signatures {
            for (tokenName, token) in baseTokens {
                for byte in UInt8.min...UInt8.max {
                    let prefixed = Data([byte]) + token
                    if key.isValidSignature(parsed, for: prefixed) {
                        remember(byte)
                        return "\(signatureName)/\(tokenName)/前置き 0x\(hex(byte))"
                    }
                    let suffixed = token + Data([byte])
                    if key.isValidSignature(parsed, for: suffixed) {
                        return "\(signatureName)/\(tokenName)/後置き 0x\(hex(byte))"
                    }
                }
            }
        }

        return nil
    }

    /// 当たった印を覚えておく。定数は分かっているので通常は使わないが、
    /// 仕様が変わったときに気付けるよう総当たりは残してある。
    /// 上流の `constants.h` にある定数。
    ///
    /// ```
    /// kNearbyShareSenderVerificationPrefix   = 0x01
    /// kNearbyShareReceiverVerificationPrefix = 0x02
    /// ```
    ///
    /// 署名する側は自分の役割の印を付け、検証する側は相手の役割の印を付ける。
    /// 同じ値だと片方の署名をそのまま返せてしまうため。
    static let senderPrefix: UInt8 = 0x01
    static let receiverPrefix: UInt8 = 0x02

    private static var learnedPrefixes: [UInt8] = [senderPrefix, receiverPrefix]

    private static func remember(_ byte: UInt8) {
        guard !learnedPrefixes.contains(byte) else { return }
        learnedPrefixes.insert(byte, at: 0)
        qlog(.ok, "PairedKey: 署名の印 0x\(hex(byte)) を覚えました")
    }

    private static func hex(_ byte: UInt8) -> String {
        String(format: "%02x", byte)
    }
}
