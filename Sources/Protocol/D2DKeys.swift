//
//  D2DKeys.swift
//  QSProbe (M2)
//
//  UKEY2 ハンドシェイク後の鍵導出チェーンと、4 桁確認 PIN の導出。
//
//  Bada の `crypto/D2DKeyDerivation.kt` / `crypto/pin/PinDerivation.kt`、
//  および QuickDrop の `NearbyConnection.finalizeKeyExchange` に対応する。
//  両者は同じ導出手順を実装しており、ここではその共通部分を Swift で書き直している。
//
//  導出チェーン:
//  ```
//  dhs            = ECDH-P256(自分の秘密鍵, 相手の公開鍵) の X 座標 (32 バイト)
//  derivedSecret  = SHA-256(dhs)
//  ukeyInfo       = clientInitMsgRaw || serverInitMsgRaw
//  authSecret     = HKDF(derivedSecret, salt="UKEY2 v1 auth", info=ukeyInfo, 32)
//  nextSecret     = HKDF(derivedSecret, salt="UKEY2 v1 next", info=ukeyInfo, 32)
//
//  d2dSalt        = SHA-256("D2D")
//  d2dClientKey   = HKDF(nextSecret, salt=d2dSalt, info="client", 32)
//  d2dServerKey   = HKDF(nextSecret, salt=d2dSalt, info="server", 32)
//
//  smsgSalt       = SHA-256("SecureMessage")
//  clientEncKey   = HKDF(d2dClientKey, salt=smsgSalt, info="ENC:2", 32)
//  clientSigKey   = HKDF(d2dClientKey, salt=smsgSalt, info="SIG:1", 32)
//  serverEncKey   = HKDF(d2dServerKey, salt=smsgSalt, info="ENC:2", 32)
//  serverSigKey   = HKDF(d2dServerKey, salt=smsgSalt, info="SIG:1", 32)
//  ```
//
//  受信側 (= server ロール) では
//    復号 = client 系、暗号化 = server 系
//  になる。ここを取り違えると HMAC は通っても復号だけ失敗するので注意。
//

import Foundation
import CryptoKit

enum Hkdf {
    static func deriveKey(ikm: SymmetricKey, salt: Data, info: Data, outputLength: Int) -> SymmetricKey {
        CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: outputLength
        )
    }

    static func deriveBytes(ikm: SymmetricKey, salt: Data, info: Data, outputLength: Int) -> [UInt8] {
        deriveKey(ikm: ikm, salt: salt, info: info, outputLength: outputLength)
            .withUnsafeBytes { [UInt8]($0) }
    }
}

/// UKEY2 完了後に確定する 1 接続分の鍵一式。
struct D2DSessionKeys {
    /// AES-256-CBC の復号鍵 (受信側では client 系)。
    let decryptKey: [UInt8]
    /// AES-256-CBC の暗号化鍵 (受信側では server 系)。
    let encryptKey: [UInt8]
    /// 受信フレームの HMAC 検証鍵。
    let receiveHmacKey: SymmetricKey
    /// 送信フレームの HMAC 生成鍵。
    let sendHmacKey: SymmetricKey
    /// UKEY2 の authString。PIN の元になる。
    let authKey: SymmetricKey

    /// 4 桁の確認 PIN。
    var pinCode: String {
        PinDerivation.deriveFourDigitPin(authKey.withUnsafeBytes { Data($0) })
    }

    /// - Parameters:
    ///   - sharedSecretX: ECDH で得た共有点の X 座標 (32 バイト)
    ///   - clientInitRaw: 受信した ClientInit の Ukey2Message 生バイト
    ///   - serverInitRaw: 送信した ServerInit の Ukey2Message 生バイト
    ///   - isServer: 自分が受信側 (server ロール) かどうか
    static func derive(
        sharedSecretX: Data,
        clientInitRaw: Data,
        serverInitRaw: Data,
        isServer: Bool
    ) -> D2DSessionKeys {
        let derivedSecret = Data(SHA256.hash(data: sharedSecretX))

        var ukeyInfo = Data()
        ukeyInfo.append(clientInitRaw)
        ukeyInfo.append(serverInitRaw)

        let ikm = SymmetricKey(data: derivedSecret)
        let authSecret = Hkdf.deriveKey(
            ikm: ikm,
            salt: Data("UKEY2 v1 auth".utf8),
            info: ukeyInfo,
            outputLength: 32
        )
        let nextSecret = Hkdf.deriveKey(
            ikm: ikm,
            salt: Data("UKEY2 v1 next".utf8),
            info: ukeyInfo,
            outputLength: 32
        )

        let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
        let d2dClientKey = Hkdf.deriveKey(
            ikm: nextSecret, salt: d2dSalt, info: Data("client".utf8), outputLength: 32
        )
        let d2dServerKey = Hkdf.deriveKey(
            ikm: nextSecret, salt: d2dSalt, info: Data("server".utf8), outputLength: 32
        )

        let smsgSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))
        let clientEnc = Hkdf.deriveBytes(
            ikm: d2dClientKey, salt: smsgSalt, info: Data("ENC:2".utf8), outputLength: 32
        )
        let clientSig = Hkdf.deriveKey(
            ikm: d2dClientKey, salt: smsgSalt, info: Data("SIG:1".utf8), outputLength: 32
        )
        let serverEnc = Hkdf.deriveBytes(
            ikm: d2dServerKey, salt: smsgSalt, info: Data("ENC:2".utf8), outputLength: 32
        )
        let serverSig = Hkdf.deriveKey(
            ikm: d2dServerKey, salt: smsgSalt, info: Data("SIG:1".utf8), outputLength: 32
        )

        if isServer {
            return D2DSessionKeys(
                decryptKey: clientEnc,
                encryptKey: serverEnc,
                receiveHmacKey: clientSig,
                sendHmacKey: serverSig,
                authKey: authSecret
            )
        } else {
            return D2DSessionKeys(
                decryptKey: serverEnc,
                encryptKey: clientEnc,
                receiveHmacKey: serverSig,
                sendHmacKey: clientSig,
                authKey: authSecret
            )
        }
    }
}

/// Chromium 由来の 4 桁 PIN 導出。
///
/// Bada の `PinDerivation.kt` と同一のアルゴリズム。移植時の注意点はそちらの
/// ドキュメントコメントが詳しいが、要点は 2 つ:
///
///  1. **各バイトを符号付き (Int8) として扱う。** `UInt8` のまま足すと
///     0x80 以上のバイトを含む authString で相手と結果が食い違う。
///  2. **剰余は切り捨て除算。** Swift の `%` は被除数の符号を引き継ぐので
///     そのままで良い (floorMod にしてはいけない)。
enum PinDerivation {

    private static let modulus = 9973
    private static let multiplierStep = 31

    static func deriveFourDigitPin(_ authString: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in authString {
            let signed = Int(Int8(bitPattern: byte))
            hash = (hash + signed * multiplier) % modulus
            multiplier = (multiplier * multiplierStep) % modulus
        }
        return String(format: "%04d", abs(hash))
    }
}

extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}
