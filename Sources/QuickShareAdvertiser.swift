//
//  QuickShareAdvertiser.swift
//  QSProbe
//
//  mDNS で自分を広告し、TCP の着信を待つ。
//
//  サービスタイプは `_FC9F5ED42C8A._tcp.` に固定してある。実測では末尾ドットの
//  有無どちらでも動くが、`NSNetService` のドキュメントが要求する絶対名形式に
//  揃えてある。publish は `NetService` を使う。`NWListener` の内蔵 Bonjour でも
//  動くことは確認済みだが、2 系統を保守する理由がないため 1 本に絞った。
//

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class QuickShareAdvertiser: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case listening(port: UInt16)
        case published(port: UInt16, instanceName: String)
        case failed(String)
    }

    /// ユーザーが「見えるようにする」を望んでいるか。
    ///
    /// 実際の `state` とは別に持つ。アプリがバックグラウンドへ回ると iOS が
    /// listener と publish を落とすため `state` は `.failed` になるが、
    /// **ユーザーの意図は変わっていない**。この 2 つを混同すると、
    /// 復帰のたびにトグルを操作し直す羽目になる。
    @Published private(set) var isEnabled = false

    @Published private(set) var state: State = .idle
    @Published private(set) var inboundConnectionCount: Int = 0

    /// アプリが前面にいるか。バックグラウンドで無駄な再試行をしないための判定。
    var isForeground = true

    /// 再試行の多重実行を防ぐ。
    private var retryScheduled = false

    /// 着信した TCP 接続の受け渡し先 (M1 で追加)。
    /// nil の場合は従来どおり即座に閉じる。
    var onInboundConnection: ((NWConnection) -> Void)?

    /// 自分自身を探索結果から除外するための、現在広告中のインスタンス名。
    @Published private(set) var currentInstanceName: String?

    /// Samsung の LAN リゾルバ対策として TXT に `IPv4` / `f` を足すかどうか。
    @Published var includeExtraTxtKeys: Bool = true


    private var listener: NWListener?
    private var netService: NetService?
    private var endpointId: [UInt8] = QuickShareMdns.randomEndpointId()

    var deviceName: String = EndpointInfo.clampName(UIDeviceNameProvider.currentName())

    // MARK: - Lifecycle

    /// トグルの操作。意図を記録したうえで開始/停止する。
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            beginAdvertising()
        } else {
            endAdvertising()
            qlog(.info, "Advertiser: 停止しました")
        }
    }

    /// 前面復帰時などに呼ぶ。意図がオンなのに動いていなければ張り直す。
    func refresh(reason: String) {
        guard isEnabled else { return }
        guard !isHealthy else { return }
        qlog(.info, "Advertiser: \(reason)ため再開します")
        endAdvertising()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.beginAdvertising()
        }
    }

    /// publish まで到達していて、まだ生きているか。
    private var isHealthy: Bool {
        if case .published = state { return listener != nil }
        if case .listening = state { return listener != nil }
        if case .starting = state { return listener != nil }
        return false
    }

    /// 旧 API 互換。内部でも使う。
    func start() {
        isEnabled = true
        beginAdvertising()
    }

    func stop() {
        isEnabled = false
        endAdvertising()
        qlog(.info, "Advertiser: 停止しました")
    }

    private func beginAdvertising() {
        guard listener == nil else {
            qlog(.warn, "Advertiser: すでに起動しています")
            return
        }
        state = .starting
        endpointId = QuickShareMdns.randomEndpointId()

        let type = QuickShareMdns.serviceType
        qlog(.info, "Advertiser: 起動 (name=\"\(deviceName)\")")

        do {
            let parameters = NWParameters(tls: .none)
            parameters.includePeerToPeer = false

            let newListener = try NWListener(using: parameters)


            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    self?.handleListenerState(newState)
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleInbound(connection)
                }
            }
            newListener.start(queue: .main)
        } catch {
            let message = "NWListener の生成に失敗: \(error)"
            qlog(.error, "Advertiser: \(message)")
            state = .failed(message)
        }
    }

    private func endAdvertising() {
        netService?.stop()
        netService = nil
        listener?.cancel()
        listener = nil
        currentInstanceName = nil
        state = .idle
    }

    /// 失敗したときに、前面にいる間だけ自動で張り直す。
    private func scheduleRetry(_ reason: String) {
        guard isEnabled, isForeground, !retryScheduled else { return }
        retryScheduled = true
        qlog(.info, "Advertiser: \(reason) — 2 秒後に再試行します")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.refresh(reason: "前回の失敗から復帰する")
        }
    }

    // MARK: - Listener

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .setup:
            qlog(.info, "Advertiser: NWListener setup")

        case .waiting(let error):
            qlog(.warn, "Advertiser: NWListener waiting — \(describe(error))")

        case .ready:
            guard let port = listener?.port?.rawValue else {
                qlog(.error, "Advertiser: ready なのにポートが取得できません")
                state = .failed("ポート取得失敗")
                return
            }
            qlog(.ok, "Advertiser: TCP listener ready (port=\(port))")
            state = .listening(port: port)
            currentInstanceName = QuickShareMdns.instanceName(endpointId: endpointId)
            publishWithNetService(port: port)

        case .failed(let error):
            let message = "NWListener failed — \(describe(error))"
            qlog(.error, "Advertiser: \(message)")
            state = .failed(message)
            scheduleRetry("listener が落ちました")

        case .cancelled:
            qlog(.info, "Advertiser: NWListener cancelled")

        @unknown default:
            break
        }
    }

    private func handleInbound(_ connection: NWConnection) {
        inboundConnectionCount += 1
        qlog(.ok, "Advertiser: ★ TCP 着信 #\(inboundConnectionCount) from \(connection.endpoint)")

        if let handler = onInboundConnection {
            // M1: フレームを読んで中身をデコードする
            handler(connection)
        } else {
            connection.cancel()
        }
    }

    /// NWError を可能な限り定数名つきで文字列化する。
    private func describe(_ error: NWError) -> String {
        if case let .dns(code) = error {
            return "\(error) [\(NetErrorNames.dnssd(Int(code)))]"
        }
        return "\(error)"
    }

    // MARK: - TXT レコード

    private func endpointInfoEncoded() -> String {
        let info = EndpointInfo(
            version: 1,
            hidden: false,
            deviceType: .tablet,
            reserved: false,
            metadata: EndpointInfo.randomMetadata(),
            deviceName: deviceName,
            tlvRecords: []
        )
        let serialized = info.serialize()
        let encoded = Base64Url.encode(serialized)
        qlog(.info, "Advertiser: EndpointInfo \(serialized.count) bytes -> n=\(encoded)")
        return encoded
    }

    /// NetService 用の `[String: Data]`。
    private func buildTxtDictionary() -> [String: Data] {
        var txt: [String: Data] = [
            QuickShareMdns.txtKeyEndpointInfo: Data(endpointInfoEncoded().utf8)
        ]
        if includeExtraTxtKeys {
            if let ipv4 = NetworkInfo.wifiIPv4Address() {
                txt[QuickShareMdns.txtKeyIPv4] = Data(ipv4.utf8)
                qlog(.info, "Advertiser: TXT IPv4=\(ipv4)")
            } else {
                qlog(.warn, "Advertiser: en0 の IPv4 アドレスを取得できませんでした")
            }
            txt[QuickShareMdns.txtKeyWifiFrequency] = Data("2437".utf8)
        }
        return txt
    }

    /// NWListener.Service 用の生 TXT データ。
    private func buildTxtRecordData() -> Data {
        var record = NWTXTRecord()
        for (key, value) in buildTxtDictionary() {
            record[key] = String(decoding: value, as: UTF8.self)
        }
        return record.data
    }

    // MARK: - NetService による publish

    private func publishWithNetService(port: UInt16) {
        let instanceName = QuickShareMdns.instanceName(endpointId: endpointId)
        let type = QuickShareMdns.serviceType

        qlog(.info, "Advertiser: instanceName=\(instanceName)")
        qlog(.info, "Advertiser: endpointId=\(String(decoding: endpointId, as: UTF8.self))")

        let txt = buildTxtDictionary()

        let service = NetService(
            domain: "",
            type: type,
            name: instanceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        netService = service

        qlog(.info, "Advertiser: NetService.publish() を呼びます (type=\"\(type)\")")
        service.publish()
        // 成否は delegate で確定する。ここで .published にはしない。
    }
}

// MARK: - NetServiceDelegate

extension QuickShareAdvertiser: NetServiceDelegate {

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        let name = sender.name
        let port = UInt16(sender.port)
        qlog(.ok, "Advertiser: ★ mDNS publish 成功 — \(name):\(port)")
        Task { @MainActor in
            self.state = .published(port: port, instanceName: name)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        let name = NetErrorNames.netServices(code)
        let hint = NetErrorNames.netServicesHint(code)

        qlog(.error, "Advertiser: ✗ mDNS publish 失敗 — \(name) (\(code))")
        if !hint.isEmpty {
            qlog(.warn, "Advertiser: → \(hint)")
        }

        Task { @MainActor in
            self.state = .failed("\(name) (\(code))")
            self.scheduleRetry("publish に失敗しました")
        }
    }

    nonisolated func netServiceDidStop(_ sender: NetService) {
        qlog(.info, "Advertiser: mDNS publish を停止しました")
    }
}

// MARK: - Device name

enum UIDeviceNameProvider {
    static func currentName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iOS Device"
        #endif
    }
}
