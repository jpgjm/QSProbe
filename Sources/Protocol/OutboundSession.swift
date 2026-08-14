//
//  OutboundSession.swift
//  QSProbe (M4)
//
//  送信側の状態機械。受信側 (`InboundSession`) と対になる。
//
//  ```
//  connecting
//    → OfflineFrame { CONNECTION_REQUEST }              平文
//    → Ukey2Message { CLIENT_INIT }                     平文
//  sentClientInit
//    ← Ukey2Message { SERVER_INIT }                     平文  (ここで鍵確定 → PIN)
//    → Ukey2Message { CLIENT_FINISH }                   平文
//    → OfflineFrame { CONNECTION_RESPONSE (accept) }    平文
//  sentClientFinish
//    ← OfflineFrame { CONNECTION_RESPONSE }             平文
//    → Sharing_Nearby_Frame { PAIRED_KEY_ENCRYPTION }   暗号化
//  sentPairedKeyEncryption
//    ← PAIRED_KEY_ENCRYPTION → 署名を検証できれば success、駄目なら unable
//    ← PAIRED_KEY_RESULT
//    → INTRODUCTION                                     ★ ファイル一覧を提示
//  sentIntroduction
//    ← response (accept / reject)                       ★ 相手が同意
//  sending
//    → PayloadTransferFrame (FILE) × N                  ★ 512 KiB ずつ
//    → DISCONNECTION
//  ```
//
//  相手 (Android) の画面には確認 PIN が出る。こちら側にも同じ PIN を出すので
//  照合できる。
//

import Foundation
import Network
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class OutboundSession: ObservableObject {

    enum Stage: String {
        case idle = "待機中"
        case connecting = "接続中"
        case sentClientInit = "CLIENT_INIT 送信済み"
        case sentClientFinish = "CLIENT_FINISH 送信済み (鍵確定)"
        case sentPairedKeyEncryption = "PAIRED_KEY 交換中"
        case sentIntroduction = "相手の同意待ち"
        case sending = "送信中"
        case completed = "送信完了"
        case rejected = "相手が拒否しました"
        case failed = "エラー"
        case closed = "切断"
    }

    /// 1 チャンクあたりのバイト数。stock 実装と同じ 512 KiB。
    private static let chunkSize = 512 * 1024

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var pinCode: String?
    @Published private(set) var lastError: String?
    @Published private(set) var targetName: String?
    @Published private(set) var files: [OutgoingFile] = []
    @Published private(set) var progressTick: Int = 0

    /// 広告から割り出した相手の証明書。`signed_data` の検証に使う。
    private var identifiedCertificate: NearbyPublicCertificate?

    /// 相手の署名を検証できたか。
    @Published private(set) var peerVerified = false

    /// 相手の `PAIRED_KEY_ENCRYPTION` に載っていた `secret_id_hash` (16 進)。
    @Published private(set) var peerSecretIdHash: String?

    private var connection: NWConnection?
    private var framed: FramedConnection?
    private var ukey2 = Ukey2Client()
    private var channel: SecureChannel?

    private var textToSend: String?
    private var textPayloadId: Int64 = 0
    private var sendQueue: [OutgoingFile] = []
    private var currentFile: OutgoingFile?

    private var lastProgressPublish = Date.distantPast
    private let progressPublishInterval: TimeInterval = 0.1

    /// 定期的に keepAlive を送るタイマー。
    ///
    /// 相手の応答に返すだけでは足りない。stock は 5 秒間隔で能動的に送ってくるし、
    /// こちらが INTRODUCTION を送ったあと相手の同意を待つ間は**こちらから
    /// 何も流れない時間**ができる。相手がユーザーの承認に時間をかけると、
    /// その沈黙で切られる恐れがある。
    private var keepAliveTimer: Timer?
    private static let keepAliveInterval: TimeInterval = 5

    /// 自分の endpoint_id。接続ごとに作り直す。
    private var endpointId: [UInt8] = QuickShareMdns.randomEndpointId()

    /// QR ペアリングで送る場合の鍵ペア。
    /// これがあると `PAIRED_KEY_ENCRYPTION` に `qr_code_handshake_data` を載せ、
    /// QR に公開鍵を出した本人であることを証明する。
    private var qrKeyPair: QrKeyPair?

    /// UKEY2 の authString。QR 署名の対象になるので保持する。
    private var ukey2AuthKey: Data?

    /// 相手に見せる名前。広告と同じ値を使う。
    /// 送信と受信で名前が違うと、相手の画面で別の端末に見える。
    var deviceName: String { DeviceNameStore.shared.effectiveName }

    var isBusy: Bool {
        switch stage {
        case .idle, .completed, .failed, .closed, .rejected: return false
        default: return true
        }
    }

    // MARK: - 開始

    /// - Parameter peerAdvertisement: 相手の `EndpointInfo.metadata`
    ///   (salt 2 + 暗号化 metadata 鍵 14)。証明書の特定に使う。
    ///   探索一覧から送るときは渡せる。QR 経由など、広告を見ていない場合は nil。
    func send(
        items: [PendingItem],
        text: String?,
        to endpoint: NWEndpoint,
        peerName: String?,
        qrKeyPair: QrKeyPair? = nil,
        peerAdvertisement: Data? = nil
    ) {
        guard !isBusy else {
            qlog(.warn, "Outbound: すでに送信中です")
            return
        }
        resetState()
        targetName = peerName
        identifyPeerCertificate(metadata: peerAdvertisement)
        self.qrKeyPair = qrKeyPair
        if qrKeyPair != nil {
            qlog(.info, "Outbound: QR ペアリング経由で送信します")
        }

        if let text, !text.isEmpty {
            textToSend = text
            textPayloadId = Int64.random(in: Int64.min...Int64.max)
        }

        var prepared: [OutgoingFile] = []
        for item in items {
            guard let file = OutgoingFile(item: item) else {
                qlog(.warn, "Outbound: ファイルを読めません — \(item.displayPath)")
                continue
            }
            prepared.append(file)
        }
        files = prepared
        sendQueue = prepared

        guard !prepared.isEmpty || textToSend != nil else {
            fail("送るものがありません")
            return
        }

        stage = .connecting
        qlog(.info, "Outbound: \(peerName ?? "?") へ接続します (\(endpoint))")

        let parameters = NWParameters(tls: .none)
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        self.framed = FramedConnection(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
        setIdleTimer(disabled: true)
    }

    func cancel() {
        stopKeepAlive()
        for file in files where !file.isComplete {
            file.abort()
        }
        framed?.cancel()
        framed = nil
        connection = nil
        setIdleTimer(disabled: false)
        if isBusy { stage = .closed }
    }

    func reset() {
        cancel()
        resetState()
        stage = .idle
    }

    private func resetState() {
        ukey2 = Ukey2Client()
        channel = nil
        textToSend = nil
        textPayloadId = 0
        sendQueue = []
        currentFile = nil
        files = []
        pinCode = nil
        lastError = nil
        targetName = nil
        progressTick = 0
        peerSecretIdHash = nil
        identifiedCertificate = nil
        peerVerified = false
        qrKeyPair = nil
        ukey2AuthKey = nil
        lastProgressPublish = .distantPast
        endpointId = QuickShareMdns.randomEndpointId()
    }

    private func setIdleTimer(disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    private func fail(_ message: String) {
        stopKeepAlive()
        qlog(.error, "Outbound: ✗ \(message)")
        lastError = message
        stage = .failed
        for file in files where !file.isComplete {
            file.abort()
        }
        framed?.cancel()
        framed = nil
        connection = nil
        setIdleTimer(disabled: false)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let e as Ukey2Error: return e.description
        case let e as SecureChannelError: return e.description
        case let e as ReceiveError: return e.description
        case let e as FramedConnectionError: return e.description
        default: return "\(error)"
        }
    }

    // MARK: - 接続状態

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            qlog(.ok, "Outbound: 接続が ready になりました")
            do {
                try startHandshake()
            } catch {
                fail(describe(error))
            }
            readNext()
        case .waiting(let error):
            qlog(.warn, "Outbound: waiting — \(error)")
        case .failed(let error):
            fail("接続に失敗しました — \(error)")
        case .cancelled:
            qlog(.info, "Outbound: 接続を閉じました")
        default:
            break
        }
    }

    // MARK: - ハンドシェイク

    private func startHandshake() throws {
        // 1) CONNECTION_REQUEST
        //
        // ここに載せる 16 バイトから、相手はこちらの証明書を特定する。
        // 広告 (mDNS) 側だけ証明書由来にしても、送信時はこちらが使われるので
        // 両方直さないと片側だけ名乗れない状態になる。
        //
        // 相手から見ると「署名は本物なのに、どの証明書のものか分からない」
        // という矛盾した相手になり、検証に失敗して接続を切られる。
        let certificateStore = LocalCertificateStore.shared
        var metadata = EndpointInfo.randomMetadata()
        var hidden = false
        if AccountStore.shared.isEnabled,
           certificateStore.useForAdvertisement,
           let certificate = certificateStore.active,
           let derived = certificate.advertisementMetadata() {
            metadata = derived
            // 公開範囲の申告も広告と揃える。
            //
            // 名前を平文で載せるのは「全ユーザーに表示」の形で、
            // 証明書で名乗ることと噛み合わない。相手から見て矛盾した
            // 申告になり、証明書の検証をしてもらえない可能性がある。
            hidden = certificateStore.hideNameInAdvertisement
            qlog(.info, "Outbound: CONNECTION_REQUEST に自分の証明書を載せます"
                + " (hidden=\(hidden))")
        }

        let info = EndpointInfo(
            version: 1,
            hidden: hidden,
            deviceType: .tablet,
            reserved: false,
            metadata: metadata,
            deviceName: deviceName,
            tlvRecords: []
        )

        var request = Location_Nearby_Connections_ConnectionRequestFrame()
        request.endpointID = Data(endpointId)
        request.endpointName = Data(deviceName.utf8)
        request.endpointInfo = info.serialize()
        // Wi-Fi LAN のみ対応。他を並べると相手がアップグレードを試みて余計に遅くなる。
        request.mediums = [.wifiLan]

        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1 = Location_Nearby_Connections_V1Frame()
        frame.v1.type = .connectionRequest
        frame.v1.connectionRequest = request

        framed?.sendFrame(try frame.serializedData())
        qlog(.ok, "Outbound: ★ CONNECTION_REQUEST を送信しました (endpoint_id=\(String(decoding: endpointId, as: UTF8.self)))")

        // 2) UKEY2 CLIENT_INIT
        let clientInit = try ukey2.makeClientInit()
        framed?.sendFrame(clientInit)
        qlog(.ok, "Outbound: ★ CLIENT_INIT を送信しました (\(clientInit.count) バイト)")
        stage = .sentClientInit
    }

    // MARK: - 受信ループ

    private func readNext() {
        guard let framed else { return }
        framed.receiveFrame { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    self.process(payload)
                    self.readNext()
                case .failure(let error):
                    // 送信完了後に相手が閉じるのは正常。ENODATA(96) / ECONNRESET(54) も同様。
                    if self.stage == .completed || self.stage == .rejected {
                        qlog(.info, "Outbound: 接続を終了しました")
                    } else if case .closedByPeer = error {
                        qlog(.info, "Outbound: 相手が接続を閉じました")
                    } else {
                        qlog(.warn, "Outbound: 受信終了 — \(error.description)")
                    }
                    self.setIdleTimer(disabled: false)
                    self.stopKeepAlive()
                    if self.isBusy { self.stage = .closed }
                    self.framed = nil
                }
            }
        }
    }

    private func process(_ payload: Data) {
        do {
            switch stage {
            case .sentClientInit:
                try handleServerInit(payload)
            case .sentClientFinish:
                try handlePlaintextConnectionResponse(payload)
            default:
                try handleEncrypted(payload)
            }
        } catch {
            fail(describe(error))
        }
    }

    // 3) SERVER_INIT → 鍵確定 → CLIENT_FINISH + CONNECTION_RESPONSE
    private func handleServerInit(_ payload: Data) throws {
        let (keys, clientFinish) = try ukey2.handleServerInit(raw: payload)
        channel = SecureChannel(keys: keys)
        ukey2AuthKey = keys.authKey.rawData

        let pin = keys.pinCode
        pinCode = pin
        qlog(.ok, "Outbound: ★★ UKEY2 完了。確認 PIN = \(pin)")

        framed?.sendFrame(clientFinish)
        qlog(.ok, "Outbound: ★ CLIENT_FINISH を送信しました")

        var response = Location_Nearby_Connections_OfflineFrame()
        response.version = .v1
        response.v1 = Location_Nearby_Connections_V1Frame()
        response.v1.type = .connectionResponse
        response.v1.connectionResponse = Location_Nearby_Connections_ConnectionResponseFrame()
        response.v1.connectionResponse.response = .accept
        response.v1.connectionResponse.status = 0
        response.v1.connectionResponse.osInfo = Location_Nearby_Connections_OsInfo()
        response.v1.connectionResponse.osInfo.type = .apple
        framed?.sendFrame(try response.serializedData())
        qlog(.ok, "Outbound: ★ CONNECTION_RESPONSE (accept) を送信しました")

        stage = .sentClientFinish
    }

    // 4) 相手の CONNECTION_RESPONSE → 暗号化チャネルへ
    private func handlePlaintextConnectionResponse(_ payload: Data) throws {
        let frame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: payload)
        guard frame.hasV1 else { return }

        if frame.v1.type == .keepAlive { return }

        guard frame.v1.type == .connectionResponse else {
            qlog(.warn, "Outbound: CONNECTION_RESPONSE を期待しましたが \(frame.v1.type) でした")
            return
        }
        guard frame.v1.connectionResponse.response == .accept else {
            throw Ukey2Error.missingField("相手が接続を拒否しました")
        }

        qlog(.ok, "Outbound: ★★ 暗号化チャネルに移行しました")
        startKeepAlive()

        var paired = Sharing_Nearby_Frame()
        paired.version = .v1
        paired.v1 = Sharing_Nearby_V1Frame()
        paired.v1.type = .pairedKeyEncryption
        paired.v1.pairedKeyEncryption = Sharing_Nearby_PairedKeyEncryptionFrame()
        paired.v1.pairedKeyEncryption.secretIDHash = Ukey2Server.randomData(6)
        paired.v1.pairedKeyEncryption.signedData = Ukey2Server.randomData(72)

        // 自分の証明書があれば、乱数ではなく本物を載せる。
        //
        // アカウントに端末を登録すると、相手は**こちらを検証できて当然**と
        // みなす。登録済みなのに乱数を返すと「おかしい」と判断されて
        // 接続を切られる。登録したなら名乗る、が対になっている。
        //
        // 印は役割で変わる (送信側 0x01 / 受信側 0x02)。
        if AccountStore.shared.isEnabled,
           let certificate = LocalCertificateStore.shared.active,
           let token = ukey2AuthKey,
           let signature = certificate.sign(authToken: token, isSender: true) {
            paired.v1.pairedKeyEncryption.signedData = signature
            // `secret_id_hash` は**相手の証明書**の secret_key で作る。
            // 「あなたを認識しています」という意味の値なので、
            // 自分の鍵で作っても相手には無意味。
            // 相手が分からないときは、上流と同じく乱数のままにする。
            if let peer = identifiedCertificate {
                paired.v1.pairedKeyEncryption.secretIDHash =
                    CertificateStore.authenticationTokenHash(
                        token: token, secretKey: peer.secretKey
                    )
            }
            qlog(.ok, "Outbound:   ★ 自分の証明書で署名しました (送信側の印)")
        }

        // QR 経由なら、QR に公開鍵を出した本人であることを証明する。
        // 署名対象は UKEY2 の authString なのでセッションごとに変わり、再生できない。
        if let qrKeyPair, let ukey2AuthKey {
            if let signature = QrHandshakeSigner.sign(
                ukey2AuthKey: ukey2AuthKey,
                privateKey: qrKeyPair.privateKey
            ) {
                paired.v1.pairedKeyEncryption.qrCodeHandshakeData = signature
                qlog(.ok, "Outbound:   ★ qr_code_handshake_data \(signature.count) バイトを載せます")
            } else {
                qlog(.warn, "Outbound:   QR ハンドシェイク署名の生成に失敗しました")
            }
        }

        try sendTransferSetupFrame(paired, label: "PAIRED_KEY_ENCRYPTION")

        stage = .sentPairedKeyEncryption
    }

    // 5) 暗号化フレーム
    private func handleEncrypted(_ payload: Data) throws {
        guard let channel else {
            throw SecureChannelError.missingField("SecureChannel が未初期化です")
        }
        guard let frame = try channel.decrypt(secureMessageData: payload) else { return }

        switch frame.v1.type {
        case .keepAlive:
            let needsAck = !frame.v1.hasKeepAlive || !frame.v1.keepAlive.ack
            qlog(.info, "Outbound: keepAlive を受信\(needsAck ? " (ACK を返します)" : " (ACK)")")
            if needsAck {
                sendKeepAlive(ack: true)
            }
            return
        case .disconnection:
            qlog(.info, "Outbound: 相手から DISCONNECTION を受信しました")
            return
        case .bandwidthUpgradeNegotiation, .bandwidthUpgradeRetry:
            return
        case .payloadTransfer:
            break
        default:
            return
        }

        let transfer = frame.v1.payloadTransfer
        guard transfer.hasPayloadChunk, transfer.payloadHeader.type == .bytes else { return }

        // 相手からの制御フレームは BYTES ペイロードで届く
        let chunk = transfer.payloadChunk
        guard (chunk.flags & 1) != 0 || !chunk.body.isEmpty else { return }

        // 制御フレームは小さいので 1 チャンクに収まる前提で扱う
        guard !chunk.body.isEmpty,
              let inner = try? Sharing_Nearby_Frame(serializedBytes: chunk.body),
              inner.hasV1 else {
            return
        }

        switch inner.v1.type {
        case .pairedKeyEncryption:
            logPairedKeyIdentity(inner.v1.pairedKeyEncryption)
            var result = Sharing_Nearby_Frame()
            result.version = .v1
            result.v1 = Sharing_Nearby_V1Frame()
            result.v1.type = .pairedKeyResult
            result.v1.pairedKeyResult = Sharing_Nearby_PairedKeyResultFrame()
            result.v1.pairedKeyResult.status = peerVerified ? .success : .unable
            try sendTransferSetupFrame(
                result,
                label: peerVerified
                    ? "PAIRED_KEY_RESULT (success)" : "PAIRED_KEY_RESULT (unable)"
            )

        case .pairedKeyResult:
            guard stage == .sentPairedKeyEncryption else { return }
            // 相手がこちらをどう判定したかを残す。
            // 転送が始まらないとき、原因がこちら側の名乗りにあるのか
            // 相手の同意待ちなのかを、ここで切り分けられる。
            let status = inner.v1.pairedKeyResult.status
            switch status {
            case .success:
                qlog(.ok, "Outbound: ★ 相手がこちらを検証しました (success)")
            case .fail:
                qlog(.warn, "Outbound: ⚠ 相手の検証に失敗しました (fail)")
                qlog(.info, "Outbound:   こちらの署名か、CONNECTION_REQUEST に載せた"
                    + " 16 バイトが噛み合っていません")
            case .unable:
                qlog(.info, "Outbound: 相手は検証できませんでした (unable)")
            default:
                qlog(.info, "Outbound: 相手の PAIRED_KEY_RESULT = \(status)")
            }
            try sendIntroduction()

        case .response:
            try handleConsentResponse(inner)

        case .cancel:
            qlog(.warn, "Outbound: 相手が転送をキャンセルしました")
            stage = .closed
            setIdleTimer(disabled: false)

        default:
            break
        }
    }

    // 6) INTRODUCTION
    private func sendIntroduction() throws {
        var introduction = Sharing_Nearby_IntroductionFrame()

        if let textToSend {
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .text
            meta.textTitle = textToSend
            meta.size = Int64(textToSend.utf8.count)
            meta.payloadID = textPayloadId
            meta.id = Int64.random(in: Int64.min...Int64.max)
            introduction.textMetadata = [meta]
            qlog(.info, "Outbound:   テキスト \(meta.size) バイト")
        }

        for file in files {
            var meta = Sharing_Nearby_FileMetadata()
            meta.name = file.name
            meta.type = file.fileType
            meta.payloadID = file.payloadId
            meta.size = file.totalSize
            meta.mimeType = file.mimeType
            meta.id = file.metadataId
            if !file.parentFolder.isEmpty {
                meta.parentFolder = file.parentFolder
            }
            introduction.fileMetadata.append(meta)
            qlog(.info, "Outbound:   \(file.displayPath) (\(file.totalSize) バイト, \(file.mimeType))")
        }

        var frame = Sharing_Nearby_Frame()
        frame.version = .v1
        frame.v1 = Sharing_Nearby_V1Frame()
        frame.v1.type = .introduction
        frame.v1.introduction = introduction
        try sendTransferSetupFrame(frame, label: "INTRODUCTION")

        stage = .sentIntroduction
        qlog(.ok, "Outbound: ★★ 相手の同意待ちです")
    }

    // 7) 相手の同意
    private func handleConsentResponse(_ frame: Sharing_Nearby_Frame) throws {
        guard stage == .sentIntroduction else { return }
        let status = frame.v1.connectionResponse.status
        qlog(.info, "Outbound: 相手の応答 = \(status)")

        switch status {
        case .accept:
            stage = .sending
            qlog(.ok, "Outbound: ★★ 相手が受け入れました。送信を開始します")
            if let textToSend {
                try sendBytesPayload(Data(textToSend.utf8), id: textPayloadId)
                self.textToSend = nil
            }
            try startNextFile()
        case .reject:
            stage = .rejected
            qlog(.info, "Outbound: 相手が拒否しました")
            finishAndDisconnect()
        default:
            fail("相手が受け取れませんでした (\(status))")
        }
    }

    // MARK: - ファイル送信

    private func startNextFile() throws {
        currentFile?.finish()

        guard !sendQueue.isEmpty else {
            stage = .completed
            qlog(.ok, "Outbound: ★★★ すべての送信が完了しました")
            finishAndDisconnect()
            return
        }

        let file = sendQueue.removeFirst()
        try file.open()
        currentFile = file
        qlog(.info, "Outbound: \(file.displayPath) の送信を開始します")
        try sendNextChunk()
    }

    private func sendNextChunk() throws {
        guard let channel, let framed, let file = currentFile else { return }
        guard stage == .sending else { return }

        let offset = file.sentBytes
        let body = try file.readChunk(maxBytes: Self.chunkSize)

        if body.isEmpty {
            // 終端。空の LAST_CHUNK を別フレームで送る。
            var transfer = Location_Nearby_Connections_PayloadTransferFrame()
            transfer.packetType = .data
            transfer.payloadHeader.id = file.payloadId
            transfer.payloadHeader.type = .file
            transfer.payloadHeader.totalSize = file.totalSize
            transfer.payloadHeader.isSensitive = false
            transfer.payloadHeader.fileName = file.name
            if !file.parentFolder.isEmpty {
                transfer.payloadHeader.parentFolder = file.parentFolder
            }
            transfer.payloadChunk.offset = file.totalSize
            transfer.payloadChunk.flags = 1

            var wrapper = Location_Nearby_Connections_OfflineFrame()
            wrapper.version = .v1
            wrapper.v1 = Location_Nearby_Connections_V1Frame()
            wrapper.v1.type = .payloadTransfer
            wrapper.v1.payloadTransfer = transfer
            framed.sendFrame(try channel.encrypt(offlineFrame: wrapper))

            qlog(.ok, "Outbound: ★★★ 送信完了 — \(file.displayPath) (\(file.totalSize) バイト)")
            progressTick &+= 1
            try startNextFile()
            return
        }

        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader.id = file.payloadId
        transfer.payloadHeader.type = .file
        transfer.payloadHeader.totalSize = file.totalSize
        transfer.payloadHeader.isSensitive = false
        transfer.payloadHeader.fileName = file.name
        if !file.parentFolder.isEmpty {
            transfer.payloadHeader.parentFolder = file.parentFolder
        }
        transfer.payloadChunk.offset = offset
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = body

        var wrapper = Location_Nearby_Connections_OfflineFrame()
        wrapper.version = .v1
        wrapper.v1 = Location_Nearby_Connections_V1Frame()
        wrapper.v1.type = .payloadTransfer
        wrapper.v1.payloadTransfer = transfer

        // 送信完了を待ってから次のチャンクを読む (バックプレッシャ)。
        // 待たずに回すとメモリにフレームが積み上がって jetsam に殺される。
        framed.sendFrame(try channel.encrypt(offlineFrame: wrapper)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail("チャンクの送信に失敗しました — \(error)")
                    return
                }
                let now = Date()
                if now.timeIntervalSince(self.lastProgressPublish) >= self.progressPublishInterval {
                    self.lastProgressPublish = now
                    self.progressTick &+= 1
                }
                do {
                    try self.sendNextChunk()
                } catch {
                    self.fail(self.describe(error))
                }
            }
        }
    }

    private func finishAndDisconnect() {
        stopKeepAlive()
        sendDisconnection()
        setIdleTimer(disabled: false)
        // 相手が DISCONNECTION を処理する余裕を持たせてから閉じる
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.framed?.cancel()
            self?.framed = nil
            self?.connection = nil
        }
    }

    /// 相手の `PAIRED_KEY_ENCRYPTION` に載っている識別子を計測用に出力する。
    ///
    /// 受信側 (`InboundSession.logPairedKeyIdentity`) と同じ値が出るかを
    /// 比べるためにこちらにも置いてある。送信・受信のどちらの立場で見ても
    /// 同じ端末が同じ `secret_id_hash` を出すなら、照合キーとして使える。
    /// 探索一覧で見た広告から、相手の証明書を割り出す。
    private func identifyPeerCertificate(metadata: Data?) {
        identifiedCertificate = nil
        peerVerified = false

        guard AccountStore.shared.isEnabled else { return }
        guard let metadata, metadata.count >= 16 else {
            qlog(.info, "Outbound: 相手の広告を持っていないので、証明書は特定できません")
            return
        }
        let pool = CertificateStore.shared.certificates.map { $0.certificate }
        guard !pool.isEmpty else { return }

        if let match = AdvertisementIdentity.identify(metadata: metadata, certificates: pool) {
            identifiedCertificate = match.certificate
            qlog(.ok, "Outbound: ★★★ 相手の証明書を特定しました")
            if let metadata = CertificateMetadata.decrypt(match.certificate) {
                qlog(.ok, "Outbound:   持ち主 = \(metadata.summary)")
            }
            qlog(.ok, "Outbound:   secret_id = "
                + "\(CertificateStore.hex(match.certificate.secretId, limit: 8))")
        } else {
            qlog(.info, "Outbound: 広告から証明書を特定できませんでした "
                + "(\(pool.count) 件と照合)")
        }
    }

    /// `secret_id_hash` から相手の証明書を割り出す。
    ///
    /// 広告からの特定と役割は同じだが、材料が違う。広告は接続の入口でしか
    /// 見られず、相手が新しい証明書に切り替えた直後などは噛み合わない。
    /// こちらは接続ごとの認証トークンから計算するので、証明書さえ持っていれば
    /// 必ず当たる。広告で外したときの受け皿になる。
    /// `secret_id_hash` が**こちらの**証明書と合うかを見る。
    ///
    /// ## この値は「相手が誰か」ではない
    ///
    /// 上流の `SendPairedKeyEncryptionFrame` はこう作っている。
    ///
    /// ```
    /// certificate_id_hash = certificate_->HashAuthenticationToken(raw_token_)
    /// ```
    ///
    /// `certificate_` は**相手の証明書**。つまり送り手は、
    /// **受け手の証明書の secret_key** で認証トークンを潰して送ってくる。
    /// 相手の証明書を持っていなければ乱数になる。
    ///
    /// したがって一致は「**相手がこちらを認識している**」ことを示す。
    /// 相手が誰かを知る手掛かりではないので、署名の検証には使えない。
    /// 以前ここで一致した証明書を検証に回していたのは誤りだった。
    private func lookUpCertificate(for hash: Data) {
        let store = CertificateStore.shared
        guard AccountStore.shared.isEnabled, !store.certificates.isEmpty else { return }
        guard let token = ukey2AuthKey else { return }

        if let stored = store.match(secretIdHash: hash, authToken: token) {
            qlog(.ok, "Outbound: ★ 相手はこちらを認識しています")
            qlog(.info, "Outbound:   相手が使ったこちらの証明書 = \(stored.summary)")
        } else {
            qlog(.info, "Outbound: 相手はこちらを認識していません (乱数を送っています)")
            qlog(.info, "Outbound:   相手がまだこちらの証明書を取得していない可能性")
        }
    }


    /// 相手 (受信側) の `signed_data` を検証する。
    ///
    /// ## なぜ送信側でも見るのか
    ///
    /// 受信側として検証できた署名の対象は `0x01 || authString` だった。
    /// この `0x01` は役割を表す印なので、**受信側が署名するときは別の値**の
    /// はず。同じ値だと片方の署名をそのまま返せてしまう。
    ///
    /// その対の値は、こちらが送信側に回って相手の署名を検証すれば分かる。
    /// **書き込みを一切せずに確かめられる**ので、自分の証明書を作る前に
    /// ここを埋めておく。
    private func verifySignedData(_ signature: Data) {
        guard AccountStore.shared.isEnabled else { return }
        guard let certificate = identifiedCertificate else {
            qlog(.info, "Outbound:   証明書を特定できていないので、署名は検証できません")
            return
        }
        guard let token = ukey2AuthKey else {
            qlog(.warn, "Outbound:   authString が無いので、署名を検証できません")
            return
        }

        if let recipe = PairedKeyVerifier.verify(
            signature: signature,
            publicKeySPKI: certificate.publicKey,
            authToken: token
        ) {
            peerVerified = true
            qlog(.ok, "Outbound:   ★★★★ 署名を検証できました (\(recipe))")
            qlog(.ok, "Outbound:     受信側が使う印が判明しました")
        } else {
            qlog(.warn, "Outbound:   署名を検証できませんでした")
            qlog(.info, "Outbound:     公開鍵 = \(certificate.publicKey.count) バイト / "
                + "署名 = \(signature.count) バイト / authString = \(token.count) バイト")
        }
    }

    private func logPairedKeyIdentity(_ frame: Sharing_Nearby_PairedKeyEncryptionFrame) {
        qlog(.info, "Outbound:   --- 識別子の計測 ---")
        if frame.hasSecretIDHash {
            let hash = frame.secretIDHash
            let hex = InboundSession.hex(hash)
            peerSecretIdHash = hex
            qlog(.ok, "Outbound:   secret_id_hash = \(hex) (\(hash.count) バイト)")
            lookUpCertificate(for: hash)
        } else {
            qlog(.warn, "Outbound:   secret_id_hash なし")
        }
        if frame.hasSignedData {
            let data = frame.signedData
            qlog(.info, "Outbound:   signed_data = \(data.count) バイト / 先頭 16 = "
                + InboundSession.hex(data, limit: 16))
            verifySignedData(data)
        }
        qlog(.info, "Outbound:   --------------------")
    }

    // MARK: - 送信ヘルパー

    /// 5 秒ごとに keepAlive を送り始める。
    private func startKeepAlive() {
        stopKeepAlive()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.keepAliveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.channel != nil, self.framed != nil else { return }
                self.sendKeepAlive(ack: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
        qlog(.info, "Outbound: keepAlive を \(Int(Self.keepAliveInterval)) 秒間隔で送ります")
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func sendKeepAlive(ack: Bool) {
        guard let channel, let framed else { return }
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1 = Location_Nearby_Connections_V1Frame()
        frame.v1.type = .keepAlive
        frame.v1.keepAlive = Location_Nearby_Connections_KeepAliveFrame()
        frame.v1.keepAlive.ack = ack
        if let encrypted = try? channel.encrypt(offlineFrame: frame) {
            framed.sendFrame(encrypted)
        }
    }

    private func sendDisconnection() {
        guard let channel, let framed else { return }
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1 = Location_Nearby_Connections_V1Frame()
        frame.v1.type = .disconnection
        frame.v1.disconnection = Location_Nearby_Connections_DisconnectionFrame()
        if let encrypted = try? channel.encrypt(offlineFrame: frame) {
            framed.sendFrame(encrypted)
            qlog(.info, "Outbound: DISCONNECTION を送信しました")
        }
    }

    private func sendTransferSetupFrame(_ frame: Sharing_Nearby_Frame, label: String) throws {
        let data = try frame.serializedData()
        try sendBytesPayload(data, id: Int64.random(in: Int64.min...Int64.max))
        qlog(.ok, "Outbound:   ★ \(label) を送信しました (\(data.count) バイト)")
    }

    /// BYTES ペイロードを、データチャンクと空の LAST_CHUNK の 2 フレームに分けて送る。
    /// Samsung One UI 7+ は融合させると無言で破棄する (Bada の記録)。
    private func sendBytesPayload(_ data: Data, id: Int64) throws {
        guard let channel, let framed else { return }

        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader.id = id
        transfer.payloadHeader.type = .bytes
        transfer.payloadHeader.totalSize = Int64(data.count)
        transfer.payloadHeader.isSensitive = false
        transfer.payloadChunk.offset = 0
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = data

        var wrapper = Location_Nearby_Connections_OfflineFrame()
        wrapper.version = .v1
        wrapper.v1 = Location_Nearby_Connections_V1Frame()
        wrapper.v1.type = .payloadTransfer
        wrapper.v1.payloadTransfer = transfer
        framed.sendFrame(try channel.encrypt(offlineFrame: wrapper))

        transfer.payloadChunk.flags = 1
        transfer.payloadChunk.offset = Int64(data.count)
        transfer.payloadChunk.clearBody()
        wrapper.v1.payloadTransfer = transfer
        framed.sendFrame(try channel.encrypt(offlineFrame: wrapper))
    }
}
