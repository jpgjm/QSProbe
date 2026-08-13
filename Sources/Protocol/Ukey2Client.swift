//
//  Ukey2Client.swift
//  QSProbe (M4)
//
//  UKEY2 の **client ロール** (= Quick Share の送信側)。
//
//  ```
//  Sender → Receiver : Ukey2Message { CLIENT_INIT }     ← ここを実装
//  Receiver → Sender : Ukey2Message { SERVER_INIT }
//  Sender → Receiver : Ukey2Message { CLIENT_FINISH }   ← ここを実装
//  ```
//
//  server ロールとの決定的な違いは **commitment を先に作る**点。
//  ClientInit に載せる commitment は「これから送る ClientFinish メッセージの
//  生バイト全体の SHA-512」なので、ClientFinish を先に組み立てておき、
//  ServerInit を受け取ったあとに**まったく同じバイト列**を送り返す必要がある。
//  作り直すと鍵ペアが変わって commitment が合わなくなる。
//

import Foundation
import CryptoKit
import SwiftProtobuf

final class Ukey2Client {

    private var privateKey: P256.KeyAgreement.PrivateKey?

    private(set) var clientInitRaw: Data?
    private(set) var clientFinishRaw: Data?
    private(set) var serverInitRaw: Data?

    /// ClientInit の生バイトを組み立てる。副作用として ClientFinish も確定させる。
    func makeClientInit() throws -> Data {
        let privateKey = P256.KeyAgreement.PrivateKey()
        self.privateKey = privateKey

        // --- 先に ClientFinish を作る (commitment の対象になるため) ---
        let x963 = privateKey.publicKey.x963Representation
        var ecKey = Securemessage_EcP256PublicKey()
        ecKey.x = Ukey2Server.asSignedBigEndian(Data(x963[1..<33]))
        ecKey.y = Ukey2Server.asSignedBigEndian(Data(x963[33..<65]))

        var genericKey = Securemessage_GenericPublicKey()
        genericKey.type = .ecP256
        genericKey.ecP256PublicKey = ecKey

        var finished = Securegcm_Ukey2ClientFinished()
        finished.publicKey = try genericKey.serializedData()

        var finishMessage = Securegcm_Ukey2Message()
        finishMessage.messageType = .clientFinish
        finishMessage.messageData = try finished.serializedData()

        let finishRaw = try finishMessage.serializedData()
        clientFinishRaw = finishRaw

        // --- ClientInit ---
        var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        commitment.commitment = Data(SHA512.hash(data: finishRaw))

        var clientInit = Securegcm_Ukey2ClientInit()
        clientInit.version = 1
        clientInit.random = Ukey2Server.randomData(32)
        clientInit.nextProtocol = Ukey2Server.expectedNextProtocol
        clientInit.cipherCommitments = [commitment]

        var initMessage = Securegcm_Ukey2Message()
        initMessage.messageType = .clientInit
        initMessage.messageData = try clientInit.serializedData()

        let initRaw = try initMessage.serializedData()
        clientInitRaw = initRaw
        return initRaw
    }

    /// ServerInit を検証し、鍵導出まで済ませる。
    /// 返り値の `clientFinish` を**そのまま**相手に送り返すこと。
    func handleServerInit(raw: Data) throws -> (keys: D2DSessionKeys, clientFinish: Data) {
        let message = try Securegcm_Ukey2Message(serializedBytes: raw)

        guard message.hasMessageType, message.hasMessageData else {
            throw Ukey2Error.missingField("Ukey2Message.message_type/message_data")
        }
        guard case .serverInit = message.messageType else {
            throw Ukey2Error.unexpectedMessageType("\(message.messageType)")
        }

        let serverInit = try Securegcm_Ukey2ServerInit(serializedBytes: message.messageData)
        guard serverInit.version == 1 else {
            throw Ukey2Error.unsupportedVersion(serverInit.version)
        }
        guard serverInit.random.count == 32 else {
            throw Ukey2Error.badRandomLength(serverInit.random.count)
        }
        guard serverInit.handshakeCipher == .p256Sha512 else {
            throw Ukey2Error.noSupportedCipher
        }

        let peerKey = try Securemessage_GenericPublicKey(serializedBytes: serverInit.publicKey)
        guard peerKey.hasEcP256PublicKey else {
            throw Ukey2Error.missingField("GenericPublicKey.ec_p256_public_key")
        }

        let x = Ukey2Server.trimTo32(peerKey.ecP256PublicKey.x)
        let y = Ukey2Server.trimTo32(peerKey.ecP256PublicKey.y)
        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)

        let peerPublicKey: P256.KeyAgreement.PublicKey
        do {
            peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: x963)
        } catch {
            throw Ukey2Error.badPeerKey("x963 として解釈できません: \(error)")
        }

        guard let privateKey, let clientInitRaw, let clientFinishRaw else {
            throw Ukey2Error.missingField("ハンドシェイク状態が揃っていません")
        }

        serverInitRaw = raw

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let sharedX = shared.withUnsafeBytes { Data($0) }

        let keys = D2DSessionKeys.derive(
            sharedSecretX: sharedX,
            clientInitRaw: clientInitRaw,
            serverInitRaw: raw,
            isServer: false
        )
        return (keys, clientFinishRaw)
    }
}
