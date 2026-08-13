//
//  Ukey2Server.swift
//  QSProbe (M2)
//
//  UKEY2 の **server ロール** (= Quick Share の受信側) を実装する。
//
//  ```
//  Sender → Receiver : Ukey2Message { CLIENT_INIT }
//  Receiver → Sender : Ukey2Message { SERVER_INIT }     ← ここを実装
//  Sender → Receiver : Ukey2Message { CLIENT_FINISH }
//  ```
//
//  QuickDrop は ECDH に SwiftECC + BigInt を使っているが、ここでは
//  **CryptoKit の P256 だけで完結**させている。外部依存を SwiftProtobuf
//  1 本に抑えられるうえ、`sharedSecretFromKeyAgreement` が返す 32 バイトが
//  そのまま共有点の X 座標なので、QuickDrop の
//  `multiplyPoint(...).x.asMagnitudeBytes()` と同じ値になる。
//

import Foundation
import CryptoKit
import SwiftProtobuf

enum Ukey2Error: Error, CustomStringConvertible {
    case unexpectedMessageType(String)
    case missingField(String)
    case unsupportedVersion(Int32)
    case badRandomLength(Int)
    case noSupportedCipher
    case unsupportedNextProtocol(String)
    case commitmentMismatch
    case badPeerKey(String)

    var description: String {
        switch self {
        case .unexpectedMessageType(let type): return "想定外の message_type: \(type)"
        case .missingField(let field): return "必須フィールドが欠けています: \(field)"
        case .unsupportedVersion(let version): return "未対応の version: \(version)"
        case .badRandomLength(let length): return "random の長さが不正: \(length)"
        case .noSupportedCipher: return "P256_SHA512 の cipher commitment がありません"
        case .unsupportedNextProtocol(let proto): return "未対応の next_protocol: \(proto)"
        case .commitmentMismatch: return "ClientFinish の commitment が一致しません"
        case .badPeerKey(let reason): return "相手の公開鍵が不正: \(reason)"
        }
    }
}

/// UKEY2 server 側のハンドシェイク状態を保持する。
final class Ukey2Server {

    /// 期待する next_protocol。これ以外は拒否する。
    static let expectedNextProtocol = "AES_256_CBC-HMAC_SHA256"

    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var cipherCommitment: Data?

    /// 受信した ClientInit の Ukey2Message 生バイト (鍵導出に必要)。
    private(set) var clientInitRaw: Data?
    /// 送信した ServerInit の Ukey2Message 生バイト (鍵導出に必要)。
    private(set) var serverInitRaw: Data?

    /// ClientInit を検証し、返送すべき ServerInit の生バイトを返す。
    func handleClientInit(raw: Data) throws -> Data {
        let message = try Securegcm_Ukey2Message(serializedBytes: raw)

        guard message.hasMessageType, message.hasMessageData else {
            throw Ukey2Error.missingField("Ukey2Message.message_type/message_data")
        }
        guard case .clientInit = message.messageType else {
            throw Ukey2Error.unexpectedMessageType("\(message.messageType)")
        }

        let clientInit = try Securegcm_Ukey2ClientInit(serializedBytes: message.messageData)

        guard clientInit.version == 1 else {
            throw Ukey2Error.unsupportedVersion(clientInit.version)
        }
        guard clientInit.random.count == 32 else {
            throw Ukey2Error.badRandomLength(clientInit.random.count)
        }
        guard clientInit.nextProtocol == Self.expectedNextProtocol else {
            throw Ukey2Error.unsupportedNextProtocol(clientInit.nextProtocol)
        }

        var commitment: Data?
        for entry in clientInit.cipherCommitments where entry.handshakeCipher == .p256Sha512 {
            commitment = entry.commitment
            break
        }
        guard let commitment else {
            throw Ukey2Error.noSupportedCipher
        }
        cipherCommitment = commitment
        clientInitRaw = raw

        // 自分の鍵ペアを生成する
        let privateKey = P256.KeyAgreement.PrivateKey()
        self.privateKey = privateKey

        // x963 表現は 0x04 || X(32) || Y(32)
        let x963 = privateKey.publicKey.x963Representation
        let x = Data(x963[1..<33])
        let y = Data(x963[33..<65])

        var genericKey = Securemessage_GenericPublicKey()
        genericKey.type = .ecP256
        var ecKey = Securemessage_EcP256PublicKey()
        // Quick Share の実装は符号付き大整数として扱うため、最上位ビットが
        // 立っている場合は 0x00 を前置する必要がある。
        ecKey.x = Self.asSignedBigEndian(x)
        ecKey.y = Self.asSignedBigEndian(y)
        genericKey.ecP256PublicKey = ecKey

        var serverInit = Securegcm_Ukey2ServerInit()
        serverInit.version = 1
        serverInit.random = Self.randomData(32)
        serverInit.handshakeCipher = .p256Sha512
        serverInit.publicKey = try genericKey.serializedData()

        var serverInitMessage = Securegcm_Ukey2Message()
        serverInitMessage.messageType = .serverInit
        serverInitMessage.messageData = try serverInit.serializedData()

        let serverInitData = try serverInitMessage.serializedData()
        serverInitRaw = serverInitData
        return serverInitData
    }

    /// ClientFinish を検証し、鍵導出まで済ませたセッション鍵を返す。
    func handleClientFinish(raw: Data) throws -> D2DSessionKeys {
        let message = try Securegcm_Ukey2Message(serializedBytes: raw)

        guard message.hasMessageType, message.hasMessageData else {
            throw Ukey2Error.missingField("Ukey2Message.message_type/message_data")
        }
        guard case .clientFinish = message.messageType else {
            throw Ukey2Error.unexpectedMessageType("\(message.messageType)")
        }

        // commitment は ClientFinish の **生バイト全体** の SHA-512
        let digest = Data(SHA512.hash(data: raw))
        guard let commitment = cipherCommitment, commitment == digest else {
            throw Ukey2Error.commitmentMismatch
        }

        let clientFinish = try Securegcm_Ukey2ClientFinished(serializedBytes: message.messageData)
        guard clientFinish.hasPublicKey else {
            throw Ukey2Error.missingField("Ukey2ClientFinished.public_key")
        }

        let peerKey = try Securemessage_GenericPublicKey(serializedBytes: clientFinish.publicKey)
        guard peerKey.hasEcP256PublicKey else {
            throw Ukey2Error.missingField("GenericPublicKey.ec_p256_public_key")
        }

        let x = Self.trimTo32(peerKey.ecP256PublicKey.x)
        let y = Self.trimTo32(peerKey.ecP256PublicKey.y)
        guard x.count == 32, y.count == 32 else {
            throw Ukey2Error.badPeerKey("x=\(x.count) バイト / y=\(y.count) バイト")
        }

        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)

        let peerPublicKey: P256.KeyAgreement.PublicKey
        do {
            peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: x963)
        } catch {
            throw Ukey2Error.badPeerKey("x963 として解釈できません: \(error)")
        }

        guard let privateKey, let clientInitRaw, let serverInitRaw else {
            throw Ukey2Error.missingField("ハンドシェイク状態が揃っていません")
        }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let sharedX = shared.withUnsafeBytes { Data($0) }

        return D2DSessionKeys.derive(
            sharedSecretX: sharedX,
            clientInitRaw: clientInitRaw,
            serverInitRaw: serverInitRaw,
            isServer: true
        )
    }

    // MARK: - ヘルパー

    /// 先頭の 0x00 パディングを落として 32 バイトに揃える。
    /// Quick Share の相手は符号付き表現で送るため 33 バイトで来ることがある。
    static func trimTo32(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 32, bytes.first == 0x00 {
            bytes.removeFirst()
        }
        while bytes.count < 32 {
            bytes.insert(0x00, at: 0)
        }
        return Data(bytes)
    }

    /// 最上位ビットが立っていれば 0x00 を前置して符号付き大整数にする。
    static func asSignedBigEndian(_ data: Data) -> Data {
        guard let first = data.first, first & 0x80 != 0 else { return data }
        var out = Data([0x00])
        out.append(data)
        return out
    }

    static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
