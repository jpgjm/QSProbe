//
//  InboundSession.swift
//  QSProbe (M3)
//
//  受信側の状態機械。M2 で暗号化チャネルまで到達したので、
//  M3 では **ユーザー同意 → 実ファイル受信** までを通す。
//
//  ```
//  initial
//    ← OfflineFrame { CONNECTION_REQUEST }              平文
//  receivedConnectionRequest
//    ← Ukey2Message { CLIENT_INIT }  → SERVER_INIT      平文
//  sentServerInit
//    ← Ukey2Message { CLIENT_FINISH }                   平文  (PIN 確定)
//  receivedClientFinish
//    ← OfflineFrame { CONNECTION_RESPONSE }             平文
//    → OfflineFrame { CONNECTION_RESPONSE (accept) }    平文
//    → Sharing_Nearby_Frame { PAIRED_KEY_ENCRYPTION }   暗号化
//  encrypted
//    ← PAIRED_KEY_ENCRYPTION → PAIRED_KEY_RESULT(unable) を返す
//    ← INTRODUCTION                                     ★ ここでユーザーに同意を求める
//  awaitingConsent
//    → Sharing_Nearby_Frame { response = ACCEPT }       ★ M3 で実装
//  receiving
//    ← PayloadTransferFrame (FILE)                      ★ ディスクへストリーミング書き込み
//  completed
//    → OfflineFrame { DISCONNECTION }
//  ```
//

import Foundation
import Network
import SwiftProtobuf
#if canImport(UIKit)
import UIKit
#endif

/// 受信した 1 フレームの要約。UI に出す用。
struct InboundFrameSummary: Identifiable {
    let id = UUID()
    let index: Int
    let byteCount: Int
    let kind: String
    let detail: String
    let isEncrypted: Bool
}

@MainActor
final class InboundSession: ObservableObject {

    enum Stage: String {
        case idle = "待機中"
        case initial = "接続受理"
        case receivedConnectionRequest = "CONNECTION_REQUEST 受信"
        case sentServerInit = "SERVER_INIT 送信済み"
        case receivedClientFinish = "CLIENT_FINISH 受信 (鍵確定)"
        case encrypted = "暗号化チャネル確立"
        case awaitingConsent = "同意待ち"
        case receiving = "受信中"
        case completed = "受信完了"
        case rejected = "拒否しました"
        case failed = "エラー"
        case closed = "切断"
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var summaries: [InboundFrameSummary] = []
    @Published private(set) var peerDeviceName: String?
    /// 4 桁の確認 PIN。Android 側の表示と一致すべき値。
    @Published private(set) var pinCode: String?
    @Published private(set) var lastError: String?

    /// INTRODUCTION で提示されたファイル群。
    @Published private(set) var files: [ReceivingFile] = []
    /// 受信し終えたテキスト。
    @Published private(set) var texts: [ReceivedText] = []
    /// 進捗表示を更新するためのカウンタ (ReceivingFile はクラスなので通知が飛ばない)。
    @Published private(set) var progressTick: Int = 0

    /// 自動承認。有効にすると INTRODUCTION を受け取った時点で確認なしに受け入れる。
    ///
    /// **既定はオフ。** 現時点では送信元を選別する手段が無いため、有効にすると
    /// 同一 LAN 上の誰からでも無確認で受け取ることになる。
    /// 送信元の照合に使える安定した識別子が無い (デバイス名は詐称可能、
    /// UKEY2 の鍵は接続ごとの使い捨て、EndpointInfo の metadata は毎回ローテーション)
    /// ため、「信頼した相手だけ」を実現できていない点に注意。
    ///
    /// 唯一の実質的な歯止めは、iOS がバックグラウンドで受信できないこと。
    /// アプリを開いて広告を出している間しか発動しない。
    @Published var autoAcceptEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoAcceptEnabled, forKey: Self.autoAcceptDefaultsKey)
            qlog(.warn, "Session: 自動承認を \(autoAcceptEnabled ? "有効" : "無効") にしました")
        }
    }

    /// 直近の転送が自動承認によるものだったか。UI に明示するために持つ。
    @Published private(set) var lastTransferWasAutoAccepted = false

    /// 相手の `PAIRED_KEY_ENCRYPTION` に載っていた `secret_id_hash` (16 進)。
    /// 接続をまたいで安定しているかを目視で比べるために保持する。
    @Published private(set) var peerSecretIdHash: String?




    /// UKEY2 の authString。QR 署名の検証対象。
    private var ukey2AuthKey: Data?

    private static let autoAcceptDefaultsKey = "QSProbe.autoAcceptEnabled"

    var hasPendingConsent: Bool { stage == .awaitingConsent }

    private var framed: FramedConnection?
    private var ukey2 = Ukey2Server()
    private var channel: SecureChannel?
    private var frameIndex = 0

    /// BYTES ペイロードの組み立てバッファ (payload_id ごと)。
    private var bytesBuffers: [Int64: Data] = [:]
    /// payload_id → 受信中ファイル。
    private var filesByPayloadId: [Int64: ReceivingFile] = [:]
    /// payload_id → テキストのタイトル。
    private var expectedTexts: [Int64: String] = [:]

    /// 進捗通知の間引き用。大きなファイルではチャンクが毎秒数百回来るため、
    /// 毎回 @Published を更新するとメインスレッドが描画で詰まる。
    private var lastProgressPublish = Date.distantPast
    private let progressPublishInterval: TimeInterval = 0.1

    /// 定期的に keepAlive を送るタイマー。応答するだけでなく、
    /// ユーザーが同意ボタンを押すまでの沈黙を埋めるために能動的にも送る。
    private var keepAliveTimer: Timer?
    private static let keepAliveInterval: TimeInterval = 5

    init() {
        // 既定はオフ。キーが無ければ false になる。
        autoAcceptEnabled = UserDefaults.standard.bool(forKey: Self.autoAcceptDefaultsKey)
    }

    // MARK: - 開始 / 終了

    func handle(connection: NWConnection) {
        framed?.cancel()
        resetState()

        stage = .initial
        let framed = FramedConnection(connection: connection)
        self.framed = framed

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
        readNext()
    }

    func cancel() {
        stopKeepAlive()
        for file in files where !file.isComplete {
            file.abort()
        }
        framed?.cancel()
        framed = nil
        setIdleTimer(disabled: false)
        stage = .closed
    }

    func reset() {
        cancel()
        resetState()
        summaries.removeAll()
        stage = .idle
    }

    private func resetState() {
        lastProgressPublish = .distantPast
        ukey2 = Ukey2Server()
        channel = nil
        frameIndex = 0
        bytesBuffers.removeAll()
        filesByPayloadId.removeAll()
        expectedTexts.removeAll()
        files = []
        texts = []
        peerDeviceName = nil
        pinCode = nil
        lastError = nil
        progressTick = 0
        lastTransferWasAutoAccepted = false
        peerSecretIdHash = nil
        ukey2AuthKey = nil
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            qlog(.ok, "Session: 接続が ready になりました")
        case .waiting(let error):
            qlog(.warn, "Session: waiting — \(error)")
        case .failed(let error):
            qlog(.error, "Session: failed — \(error)")
            setIdleTimer(disabled: false)
            stage = .failed
        case .cancelled:
            qlog(.info, "Session: 接続を閉じました")
        default:
            break
        }
    }

    /// 転送中は画面を消さない。iOS はサスペンドされるとソケットが止まるため。
    private func setIdleTimer(disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    // MARK: - ユーザー同意

    func accept() {
        guard stage == .awaitingConsent else { return }
        do {
            for file in files {
                try file.open()
            }
            var response = Sharing_Nearby_Frame()
            response.version = .v1
            response.v1 = Sharing_Nearby_V1Frame()
            response.v1.type = .response
            response.v1.connectionResponse = Sharing_Nearby_ConnectionResponseFrame()
            response.v1.connectionResponse.status = .accept
            try sendTransferSetupFrame(response, label: "RESPONSE (accept)")

            stage = .receiving
            setIdleTimer(disabled: true)
            let how = lastTransferWasAutoAccepted ? "自動承認" : "手動承認"
            qlog(.ok, "Session: ★ \(how)。ファイル \(files.count) 件の受信を開始します")
        } catch {
            fail(describe(error))
        }
    }

    func reject() {
        guard stage == .awaitingConsent else { return }
        var response = Sharing_Nearby_Frame()
        response.version = .v1
        response.v1 = Sharing_Nearby_V1Frame()
        response.v1.type = .response
        response.v1.connectionResponse = Sharing_Nearby_ConnectionResponseFrame()
        response.v1.connectionResponse.status = .reject
        try? sendTransferSetupFrame(response, label: "RESPONSE (reject)")
        stage = .rejected
        qlog(.info, "Session: 拒否しました")
        sendDisconnection()
    }

    // MARK: - 受信ループ

    private func readNext() {
        guard let framed else { return }
        framed.receiveFrame { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    self.frameIndex += 1
                    self.process(payload, index: self.frameIndex)
                    self.readNext()
                case .failure(let error):
                    if case .closedByPeer = error {
                        qlog(.info, "Session: 相手が接続を閉じました (受信 \(self.frameIndex) フレーム)")
                    } else {
                        qlog(.warn, "Session: 受信終了 — \(error.description)")
                    }
                    self.setIdleTimer(disabled: false)
                    self.stopKeepAlive()
                    if self.stage != .failed, self.stage != .completed, self.stage != .rejected {
                        self.stage = .closed
                    }
                    self.framed = nil
                }
            }
        }
    }

    private func fail(_ message: String) {
        stopKeepAlive()
        qlog(.error, "Session: ✗ \(message)")
        lastError = message
        stage = .failed
        setIdleTimer(disabled: false)
        for file in files where !file.isComplete {
            file.abort()
        }
        framed?.cancel()
        framed = nil
    }

    private func describe(_ error: Error) -> String {
        // `as? CustomStringConvertible` は常に成功してしまうため、
        // 自前のエラー型を個別に見る。
        switch error {
        case let e as Ukey2Error: return e.description
        case let e as SecureChannelError: return e.description
        case let e as ReceiveError: return e.description
        case let e as FramedConnectionError: return e.description
        default: return "\(error)"
        }
    }

    // MARK: - 状態別の処理

    private func process(_ payload: Data, index: Int) {
        // 受信中はフレーム数が膨大になるのでログを絞る
        if stage != .receiving {
            qlog(.info, "Session: フレーム #\(index) を受信 (\(payload.count) バイト, 状態=\(stage.rawValue))")
        }

        do {
            switch stage {
            case .initial:
                try handleConnectionRequest(payload, index: index)
            case .receivedConnectionRequest:
                try handleClientInit(payload, index: index)
            case .sentServerInit:
                try handleClientFinish(payload, index: index)
            case .receivedClientFinish:
                try handlePlaintextConnectionResponse(payload, index: index)
            case .encrypted, .awaitingConsent, .receiving, .completed:
                try handleEncrypted(payload, index: index)
            default:
                qlog(.warn, "Session: 状態 \(stage.rawValue) では扱えないフレームです")
            }
        } catch {
            fail(describe(error))
        }
    }

    // 1) CONNECTION_REQUEST
    private func handleConnectionRequest(_ payload: Data, index: Int) throws {
        let frame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: payload)
        guard frame.hasV1, frame.v1.hasConnectionRequest else {
            throw Ukey2Error.missingField("OfflineFrame.v1.connection_request")
        }

        let request = frame.v1.connectionRequest
        let endpointId = String(decoding: request.endpointID, as: UTF8.self)
        qlog(.ok, "Session:   ★ CONNECTION_REQUEST endpoint_id=\(endpointId)")

        var detail = "endpoint_id=\(endpointId)"
        if let info = EndpointInfo.parse(request.endpointInfo) {
            let name = info.hidden ? "(hidden)" : (info.deviceName ?? "(名前なし)")
            qlog(.ok, "Session:   ★ 相手のデバイス名 = \(name) [type=\(info.deviceType)]")
            peerDeviceName = info.hidden ? nil : info.deviceName
            detail = "\(name) / \(detail)"
        }

        append(index: index, bytes: payload.count, kind: "CONNECTION_REQUEST",
               detail: detail, encrypted: false)
        stage = .receivedConnectionRequest
    }

    // 2) CLIENT_INIT → SERVER_INIT
    private func handleClientInit(_ payload: Data, index: Int) throws {
        let serverInit = try ukey2.handleClientInit(raw: payload)
        qlog(.ok, "Session:   ★ CLIENT_INIT を検証しました (cipher=p256Sha512)")

        append(index: index, bytes: payload.count, kind: "UKEY2 CLIENT_INIT",
               detail: "next_protocol = \(Ukey2Server.expectedNextProtocol)", encrypted: false)

        framed?.sendFrame(serverInit) { error in
            if let error {
                qlog(.error, "Session:   SERVER_INIT の送信に失敗 — \(error)")
            } else {
                qlog(.ok, "Session:   ★ SERVER_INIT を送信しました (\(serverInit.count) バイト)")
            }
        }
        stage = .sentServerInit
    }

    // 3) CLIENT_FINISH → 鍵導出
    private func handleClientFinish(_ payload: Data, index: Int) throws {
        let keys = try ukey2.handleClientFinish(raw: payload)
        channel = SecureChannel(keys: keys)
        ukey2AuthKey = keys.authKey.rawData

        let pin = keys.pinCode
        pinCode = pin
        qlog(.ok, "Session:   ★★ UKEY2 完了。確認 PIN = \(pin)")

        append(index: index, bytes: payload.count, kind: "UKEY2 CLIENT_FINISH",
               detail: "鍵導出完了 / PIN = \(pin)", encrypted: false)
        stage = .receivedClientFinish
    }

    // 4) CONNECTION_RESPONSE (平文) → 応答を返して暗号化チャネルへ
    private func handlePlaintextConnectionResponse(_ payload: Data, index: Int) throws {
        let frame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: payload)
        guard frame.hasV1, frame.v1.type == .connectionResponse else {
            qlog(.warn, "Session:   CONNECTION_RESPONSE を期待しましたが \(frame.v1.type) でした")
            return
        }
        qlog(.ok, "Session:   ★ 相手の CONNECTION_RESPONSE を受信しました")
        append(index: index, bytes: payload.count, kind: "CONNECTION_RESPONSE",
               detail: "相手からの応答", encrypted: false)

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
        qlog(.ok, "Session:   ★ CONNECTION_RESPONSE (accept) を送信しました")

        stage = .encrypted
        qlog(.ok, "Session:   ★★ 暗号化チャネルに移行しました")
        startKeepAlive()

        var paired = Sharing_Nearby_Frame()
        paired.version = .v1
        paired.v1 = Sharing_Nearby_V1Frame()
        paired.v1.type = .pairedKeyEncryption
        paired.v1.pairedKeyEncryption = Sharing_Nearby_PairedKeyEncryptionFrame()
        paired.v1.pairedKeyEncryption.secretIDHash = Ukey2Server.randomData(6)
        paired.v1.pairedKeyEncryption.signedData = Ukey2Server.randomData(72)

        try sendTransferSetupFrame(paired, label: "PAIRED_KEY_ENCRYPTION")
    }

    // 5) 暗号化フレーム
    private func handleEncrypted(_ payload: Data, index: Int) throws {
        guard let channel else {
            throw SecureChannelError.missingField("SecureChannel が未初期化です")
        }
        guard let frame = try channel.decrypt(secureMessageData: payload) else { return }

        switch frame.v1.type {
        case .keepAlive:
            // ACK を返さないと相手が数十秒で切断する
            let needsAck = !frame.v1.hasKeepAlive || !frame.v1.keepAlive.ack
            qlog(.info, "Session:   keepAlive を受信\(needsAck ? " (ACK を返します)" : " (ACK)")")
            if needsAck {
                sendKeepAlive(ack: true)
            }
            return

        case .disconnection:
            qlog(.info, "Session:   相手から DISCONNECTION を受信しました")
            append(index: index, bytes: payload.count, kind: "暗号化 DISCONNECTION",
                   detail: "相手が切断を通知", encrypted: true)
            return

        case .bandwidthUpgradeRetry, .bandwidthUpgradeNegotiation:
            // Wi-Fi LAN 経路のみ対応。アップグレード要求は黙って無視する。
            return

        case .payloadTransfer:
            break

        default:
            qlog(.info, "Session:   復号 — V1.type = \(frame.v1.type)")
            append(index: index, bytes: payload.count, kind: "暗号化 \(frame.v1.type)",
                   detail: "未処理", encrypted: true)
            return
        }

        let transfer = frame.v1.payloadTransfer
        let header = transfer.payloadHeader
        let chunk = transfer.payloadChunk

        guard transfer.hasPayloadChunk else {
            // 制御メッセージ (ACK / キャンセル通知など)
            if transfer.hasControlMessage, transfer.controlMessage.event == .payloadCanceled {
                qlog(.warn, "Session:   相手がペイロードをキャンセルしました")
            }
            return
        }

        switch header.type {
        case .file:
            try handleFileChunk(payloadId: header.id, chunk: chunk, index: index, wire: payload.count)
        case .bytes:
            try handleBytesChunk(header: header, chunk: chunk, index: index, wire: payload.count)
        default:
            qlog(.info, "Session:   未対応の payload type=\(header.type)")
        }
    }

    // MARK: - FILE ペイロード

    private func handleFileChunk(
        payloadId: Int64,
        chunk: Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk,
        index: Int,
        wire: Int
    ) throws {
        guard let file = filesByPayloadId[payloadId] else {
            // 同意前に来た、あるいは知らない payload。無視する。
            return
        }

        try file.write(chunk: chunk.body, at: chunk.offset)

        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= progressPublishInterval {
            lastProgressPublish = now
            progressTick &+= 1
        }

        if (chunk.flags & 1) != 0 {
            progressTick &+= 1
            file.finish()
            qlog(.ok, "Session:   ★★★ 受信完了 — \(file.displayPath) (\(file.receivedBytes) バイト)")
            qlog(.info, "Session:     保存先 = \(file.destinationURL.lastPathComponent)")
            append(index: index, bytes: wire, kind: "ファイル受信完了",
                   detail: "\(file.displayPath) (\(file.receivedBytes) バイト)", encrypted: true)
            checkAllComplete()
        }
    }

    private func checkAllComplete() {
        guard stage == .receiving else { return }
        let filesDone = files.allSatisfy { $0.isComplete }
        let textsDone = expectedTexts.isEmpty
        guard filesDone, textsDone else { return }

        stage = .completed
        setIdleTimer(disabled: false)
        stopKeepAlive()
        qlog(.ok, "Session: ★★★ すべての受信が完了しました")
        sendDisconnection()
    }

    // MARK: - BYTES ペイロード

    private func handleBytesChunk(
        header: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader,
        chunk: Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk,
        index: Int,
        wire: Int
    ) throws {
        var buffer = bytesBuffers[header.id] ?? Data()
        guard chunk.offset == Int64(buffer.count) else {
            throw ReceiveError.offsetMismatch(
                expected: Int64(buffer.count), got: chunk.offset, name: "BYTES#\(header.id)"
            )
        }
        buffer.append(chunk.body)
        bytesBuffers[header.id] = buffer

        guard (chunk.flags & 1) != 0 else { return }
        bytesBuffers.removeValue(forKey: header.id)

        // INTRODUCTION で予告されたテキストか、転送セットアップフレームか
        if let title = expectedTexts.removeValue(forKey: header.id) {
            let body = String(decoding: buffer, as: UTF8.self)
            texts.append(ReceivedText(payloadId: header.id, title: title, body: body))
            qlog(.ok, "Session:   ★★★ テキスト受信完了 — \(title) (\(buffer.count) バイト)")
            append(index: index, bytes: wire, kind: "テキスト受信完了",
                   detail: "\(title) (\(buffer.count) バイト)", encrypted: true)
            checkAllComplete()
            return
        }

        describeTransferSetupFrame(buffer, index: index, byteCount: wire)
    }

    /// BYTES ペイロードの中身は `Sharing_Nearby_Frame`。
    private func describeTransferSetupFrame(_ data: Data, index: Int, byteCount: Int) {
        guard let frame = try? Sharing_Nearby_Frame(serializedBytes: data), frame.hasV1 else {
            qlog(.warn, "Session:   BYTES ペイロードを解釈できません (\(data.count) バイト)")
            return
        }

        let type = "\(frame.v1.type)"
        qlog(.ok, "Session:   ★★ Sharing_Nearby_Frame / V1.type = \(type)")
        var detail = type

        switch frame.v1.type {
        case .pairedKeyEncryption:
            let isLegacy = frame.v1.certificateInfo.publicCertificate.isEmpty
            detail = "PAIRED_KEY_ENCRYPTION (\(isLegacy ? "legacy" : "証明書つき"))"
            logPairedKeyIdentity(frame.v1.pairedKeyEncryption)
            sendPairedKeyResult()

        case .pairedKeyResult:
            detail = "PAIRED_KEY_RESULT / status = \(frame.v1.pairedKeyResult.status)"

        case .introduction:
            handleIntroduction(frame.v1.introduction)
            let names = files.map { $0.displayPath }
                + texts.map { $0.title }
                + Array(expectedTexts.values)
            detail = names.isEmpty ? "INTRODUCTION (内容なし)" : "INTRODUCTION: \(names.joined(separator: ", "))"

        case .cancel:
            qlog(.warn, "Session:   相手が転送をキャンセルしました")
            detail = "CANCEL"
            for file in files where !file.isComplete {
                file.abort()
            }
            if stage != .completed {
                stage = .closed
            }
            setIdleTimer(disabled: false)

        default:
            break
        }

        append(index: index, bytes: byteCount, kind: "Sharing_Nearby_Frame",
               detail: detail, encrypted: true)
    }

    private func handleIntroduction(_ introduction: Sharing_Nearby_IntroductionFrame) {
        var newFiles: [ReceivingFile] = []
        for meta in introduction.fileMetadata {
            let parentFolder = meta.hasParentFolder ? meta.parentFolder : ""
            let url = ReceiveDestination.uniqueURL(for: meta.name, parentFolder: parentFolder)
            let file = ReceivingFile(
                payloadId: meta.payloadID,
                name: meta.name,
                parentFolder: parentFolder,
                mimeType: meta.mimeType,
                totalSize: meta.size,
                destinationURL: url
            )
            newFiles.append(file)
            filesByPayloadId[meta.payloadID] = file
            qlog(.ok, "Session:     - \(file.displayPath) (\(meta.size) バイト, \(meta.mimeType))")
        }
        for meta in introduction.textMetadata {
            expectedTexts[meta.payloadID] = meta.textTitle
            qlog(.ok, "Session:     - テキスト: \(meta.textTitle) (\(meta.size) バイト)")
        }
        files = newFiles

        guard !newFiles.isEmpty || !expectedTexts.isEmpty else {
            qlog(.warn, "Session:   INTRODUCTION の中身が空です")
            return
        }

        stage = .awaitingConsent

        guard autoAcceptEnabled else {
            qlog(.ok, "Session: ★★★ 同意待ちです。PIN を確認して「受け入れる」を押してください")
            return
        }

        // 無音で受け取らない。何を誰から受け取ったかを必ず残す。
        lastTransferWasAutoAccepted = true
        qlog(.warn, "Session: ⚠ 自動承認が有効なため、確認なしで受け入れます")
        qlog(.warn, "Session:   送信元 = \(peerDeviceName ?? "(名前なし)") / PIN = \(pinCode ?? "-")")
        let itemCount = newFiles.count + expectedTexts.count
        qlog(.warn, "Session:   受け取る項目 = \(itemCount) 件")
        accept()
    }

    // MARK: - 送信ヘルパー

    /// `PAIRED_KEY_ENCRYPTION` に載っている識別子を計測用に出力する。
    ///
    /// 目的は「自動承認を特定の相手だけに限定できるか」の判断材料を集めること。
    /// 現状 QSProbe が持つ照合キーはデバイス名しかなく、それは詐称できる。
    /// UKEY2 の鍵は接続ごとの使い捨て、`EndpointInfo.metadata` は広告ごとに
    /// ローテーションするため使えない。
    ///
    /// `secret_id_hash` は stock 実装が自分の証明書に紐づけて送ってくる値なので、
    /// **証明書の有効期間中は安定している可能性**がある。安定していれば
    /// 名前より遥かに強い照合キーになる。
    ///
    /// ここで確かめたいこと:
    ///   1. 同じ端末から複数回接続したとき同じ値か
    ///   2. 日をまたいでも同じか
    ///   3. 「全ユーザーに表示」と「連絡先のみ」で変わるか
    ///   4. 送信側 (`OutboundSession`) から見た値と一致するか
    ///
    /// なお安定していても**署名を検証できない以上、値を知る第三者は名乗れる**。
    /// 「推測されにくい鍵」止まりであることは変わらない。
    private func logPairedKeyIdentity(_ frame: Sharing_Nearby_PairedKeyEncryptionFrame) {
        qlog(.info, "Session:   --- 識別子の計測 ---")

        if frame.hasSecretIDHash {
            let hash = frame.secretIDHash
            let hex = Self.hex(hash)
            peerSecretIdHash = hex
            qlog(.ok, "Session:   secret_id_hash = \(hex) (\(hash.count) バイト)")
        } else {
            qlog(.warn, "Session:   secret_id_hash なし")
        }

        if frame.hasSignedData {
            let data = frame.signedData
            qlog(.info, "Session:   signed_data = \(data.count) バイト / 先頭 16 = \(Self.hex(data, limit: 16))")
        }
        if frame.hasOptionalSignedData {
            let data = frame.optionalSignedData
            qlog(.info, "Session:   optional_signed_data = \(data.count) バイト / 先頭 16 = \(Self.hex(data, limit: 16))")
        }
        if frame.hasQrCodeHandshakeData {
            qlog(.info, "Session:   qr_code_handshake_data = \(frame.qrCodeHandshakeData.count) バイト")
        }

        qlog(.info, "Session:   --------------------")
    }

    static func hex(_ data: Data, limit: Int? = nil) -> String {
        let slice = limit.map { data.prefix($0) } ?? data.prefix(data.count)
        let body = slice.map { String(format: "%02x", $0) }.joined()
        if let limit, data.count > limit {
            return body + "…"
        }
        return body
    }

    private func sendPairedKeyResult() {
        var result = Sharing_Nearby_Frame()
        result.version = .v1
        result.v1 = Sharing_Nearby_V1Frame()
        result.v1.type = .pairedKeyResult
        result.v1.pairedKeyResult = Sharing_Nearby_PairedKeyResultFrame()
        result.v1.pairedKeyResult.status = .unable
        try? sendTransferSetupFrame(result, label: "PAIRED_KEY_RESULT (unable)")
    }

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
        qlog(.info, "Session: keepAlive を \(Int(Self.keepAliveInterval)) 秒間隔で送ります")
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
            qlog(.info, "Session: DISCONNECTION を送信しました")
        }
    }

    /// `Sharing_Nearby_Frame` を BYTES ペイロードとして暗号化送信する。
    ///
    /// データチャンクと、`offset = totalSize` の空の LAST_CHUNK を
    /// **必ず 2 フレームに分けて**送る。Bada が Samsung One UI 7+ で
    /// 「融合させると無言で破棄される」と記録している箇所。
    private func sendTransferSetupFrame(_ frame: Sharing_Nearby_Frame, label: String) throws {
        guard let channel, let framed else { return }

        let data = try frame.serializedData()
        let payloadId = Int64.random(in: Int64.min...Int64.max)

        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader.id = payloadId
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

        qlog(.ok, "Session:   ★ \(label) を送信しました (\(data.count) バイト)")
    }

    // MARK: - UI

    private func append(index: Int, bytes: Int, kind: String, detail: String, encrypted: Bool) {
        summaries.append(InboundFrameSummary(
            index: index,
            byteCount: bytes,
            kind: kind,
            detail: detail,
            isEncrypted: encrypted
        ))
        if summaries.count > 80 {
            summaries.removeFirst(summaries.count - 80)
        }
    }
}
