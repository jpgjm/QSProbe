//
//  SecureChannel.swift
//  QSProbe (M2)
//
//  UKEY2 完了後の暗号化チャネル。
//  Bada の `crypto/securemessage/SecureMessageCodec.kt` + `SecureChannel.kt`、
//  QuickDrop の `encryptAndSendOfflineFrame` / `decryptAndProcessReceivedSecureMessage`
//  に対応する。
//
//  ワイヤ構造:
//  ```
//  SecureMessage {
//    header_and_body = HeaderAndBody {
//       header = { encryption_scheme: AES_256_CBC,
//                  signature_scheme: HMAC_SHA256,
//                  iv: 16 バイト,
//                  public_metadata: GcmMetadata{ type: DEVICE_TO_DEVICE_MESSAGE, version: 1 } }
//       body   = AES-256-CBC(PKCS7) { DeviceToDeviceMessage { sequence_number, message } }
//    }
//    signature = HMAC-SHA256(header_and_body)
//  }
//  ```
//
//  重要な点が 2 つある。
//
//  1. **HMAC は復号より先に検証する。** 復号してから検証すると padding oracle に
//     なる。Bada が `SecureChannel.kt` で「HMAC-before-decrypt」と明記している
//     のと同じ理由。
//  2. **シーケンス番号は送受信で別々に進む。** 送信は 1 から始めて毎回 +1、
//     受信は「前回 +1」を期待する。ずれたら異常。
//
//  AES-256-CBC は CryptoKit に無いので CommonCrypto の `CCCrypt` を使う。
//

import Foundation
import CryptoKit
import CommonCrypto
import SwiftProtobuf

enum SecureChannelError: Error, CustomStringConvertible {
    case badSignature
    case cryptoFailure(Int32)
    case missingField(String)
    case sequenceMismatch(expected: Int32, got: Int32)
    case staleSequence(Int32)

    var description: String {
        switch self {
        case .badSignature: return "HMAC が一致しません"
        case .cryptoFailure(let status): return "CCCrypt が失敗しました (status=\(status))"
        case .missingField(let field): return "必須フィールドが欠けています: \(field)"
        case .sequenceMismatch(let expected, let got):
            return "シーケンス番号が不正 (期待 \(expected) / 実際 \(got))"
        case .staleSequence(let seq): return "古い/重複したシーケンス番号 \(seq)"
        }
    }
}

final class SecureChannel {

    private let keys: D2DSessionKeys

    /// 自分が送信したフレーム数。
    private var sendSequence: Int32 = 0
    /// 相手から受信したフレームの最新シーケンス番号。
    private var receiveSequence: Int32 = 0

    init(keys: D2DSessionKeys) {
        self.keys = keys
    }

    // MARK: - 送信

    /// OfflineFrame を暗号化して SecureMessage の生バイトにする。
    func encrypt(offlineFrame: Location_Nearby_Connections_OfflineFrame) throws -> Data {
        sendSequence += 1

        var d2d = Securegcm_DeviceToDeviceMessage()
        d2d.sequenceNumber = sendSequence
        d2d.message = try offlineFrame.serializedData()
        let plaintext = try d2d.serializedData()

        let iv = Ukey2Server.randomData(16)
        let ciphertext = try Self.crypt(
            operation: CCOperation(kCCEncrypt),
            key: keys.encryptKey,
            iv: iv,
            input: plaintext
        )

        var header = Securemessage_Header()
        header.encryptionScheme = .aes256Cbc
        header.signatureScheme = .hmacSha256
        header.iv = iv

        var metadata = Securegcm_GcmMetadata()
        metadata.type = .deviceToDeviceMessage
        metadata.version = 1
        header.publicMetadata = try metadata.serializedData()

        var headerAndBody = Securemessage_HeaderAndBody()
        headerAndBody.header = header
        headerAndBody.body = ciphertext

        var secure = Securemessage_SecureMessage()
        secure.headerAndBody = try headerAndBody.serializedData()
        secure.signature = Data(
            HMAC<SHA256>.authenticationCode(for: secure.headerAndBody, using: keys.sendHmacKey)
        )
        return try secure.serializedData()
    }

    // MARK: - 受信

    /// SecureMessage の生バイトを検証・復号して OfflineFrame を返す。
    /// 重複フレームだった場合は nil を返す (エラーではない)。
    func decrypt(secureMessageData: Data) throws -> Location_Nearby_Connections_OfflineFrame? {
        let secure = try Securemessage_SecureMessage(serializedBytes: secureMessageData)
        guard secure.hasSignature, secure.hasHeaderAndBody else {
            throw SecureChannelError.missingField("SecureMessage.signature/header_and_body")
        }

        // --- HMAC を復号より先に検証する ---
        let expected = Data(
            HMAC<SHA256>.authenticationCode(for: secure.headerAndBody, using: keys.receiveHmacKey)
        )
        guard Self.constantTimeEquals(expected, secure.signature) else {
            throw SecureChannelError.badSignature
        }

        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: secure.headerAndBody)
        let plaintext = try Self.crypt(
            operation: CCOperation(kCCDecrypt),
            key: keys.decryptKey,
            iv: headerAndBody.header.iv,
            input: headerAndBody.body
        )

        let d2d = try Securegcm_DeviceToDeviceMessage(serializedBytes: plaintext)
        guard d2d.hasMessage, d2d.hasSequenceNumber else {
            throw SecureChannelError.missingField("DeviceToDeviceMessage.message/sequence_number")
        }

        let received = d2d.sequenceNumber
        let expectedSeq = receiveSequence + 1
        if received == expectedSeq {
            receiveSequence = received
        } else if received <= receiveSequence {
            // 相手のリトライ。無視して良い。
            return nil
        } else {
            throw SecureChannelError.sequenceMismatch(expected: expectedSeq, got: received)
        }

        return try Location_Nearby_Connections_OfflineFrame(serializedBytes: d2d.message)
    }

    // MARK: - 低レベル

    private static func crypt(
        operation: CCOperation,
        key: [UInt8],
        iv: Data,
        input: Data
    ) throws -> Data {
        let inputBytes = [UInt8](input)
        let ivBytes = [UInt8](iv)
        var output = Data(count: inputBytes.count + kCCBlockSizeAES128)
        var outputLength = 0
        var status: CCCryptorStatus = CCCryptorStatus(kCCSuccess)

        output.withUnsafeMutableBytes { rawBuffer in
            status = CCCrypt(
                operation,
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                key, kCCKeySizeAES256,
                ivBytes,
                inputBytes, inputBytes.count,
                rawBuffer.baseAddress, rawBuffer.count,
                &outputLength
            )
        }

        guard status == CCCryptorStatus(kCCSuccess) else {
            throw SecureChannelError.cryptoFailure(status)
        }
        return output.prefix(outputLength)
    }

    /// 定数時間比較。`==` は早期リターンするため HMAC の比較には使わない。
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[rhs.startIndex + (index - lhs.startIndex)]
        }
        return diff == 0
    }
}
