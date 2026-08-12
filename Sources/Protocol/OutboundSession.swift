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
//    ← PAIRED_KEY_ENCRYPTION → PAIRED_KEY_RESULT(unable) を返す
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

    /// 自分の endpoint_id。接続ごとに作り直す。
    private var endpointId: [UInt8] = QuickShareMdns.randomEndpointId()

    var deviceName: String = EndpointInfo.clampName(UIDeviceNameProvider.currentName())

    var isBusy: Bool {
        switch stage {
        case .idle, .completed, .failed, .closed, .rejected: return false
        default: return true
        }
    }

    // MARK: - 開始

    func send(items: [PendingItem], text: String?, to endpoint: NWEndpoint, peerName: String?) {
        guard !isBusy else {
            qlog(.warn, "Outbound: すでに送信中です")
            return
        }
        resetState()
        targetName = peerName

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
        lastProgressPublish = .distantPast
        endpointId = QuickShareMdns.randomEndpointId()
    }

    private func setIdleTimer(disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    private func fail(_ message: String) {
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
        let info = EndpointInfo(
            version: 1,
            hidden: false,
            deviceType: .tablet,
            reserved: false,
            metadata: EndpointInfo.randomMetadata(),
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

        var paired = Sharing_Nearby_Frame()
        paired.version = .v1
        paired.v1 = Sharing_Nearby_V1Frame()
        paired.v1.type = .pairedKeyEncryption
        paired.v1.pairedKeyEncryption = Sharing_Nearby_PairedKeyEncryptionFrame()
        paired.v1.pairedKeyEncryption.secretIDHash = Ukey2Server.randomData(6)
        paired.v1.pairedKeyEncryption.signedData = Ukey2Server.randomData(72)
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
            if !frame.v1.hasKeepAlive || !frame.v1.keepAlive.ack {
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
            var result = Sharing_Nearby_Frame()
            result.version = .v1
            result.v1 = Sharing_Nearby_V1Frame()
            result.v1.type = .pairedKeyResult
            result.v1.pairedKeyResult = Sharing_Nearby_PairedKeyResultFrame()
            result.v1.pairedKeyResult.status = .unable
            try sendTransferSetupFrame(result, label: "PAIRED_KEY_RESULT (unable)")

        case .pairedKeyResult:
            guard stage == .sentPairedKeyEncryption else { return }
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
        sendDisconnection()
        setIdleTimer(disabled: false)
        // 相手が DISCONNECTION を処理する余裕を持たせてから閉じる
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.framed?.cancel()
            self?.framed = nil
            self?.connection = nil
        }
    }

    // MARK: - 送信ヘルパー

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
