//
//  QuickShareAdvertiser.swift
//  QSProbe
//
//  ## 経緯 (訂正済み)
//
//  初版は `NetService.publish()` が -72008
//  (NSNetServicesMissingRequiredConfigurationError) で失敗し、
//  ローカルネットワークの権限プロンプトすら出なかった。
//
//  当初これを「サービスタイプの末尾ドットの問題」と推測して切り替え機能を
//  入れたが、**それは誤りだった**。真因は **LiveContainer 上でアプリを
//  起動していたこと**。ゲストアプリはホストのプロセス内で動くため、
//  Bonjour のサービスタイプ照合はホスト側の `NSBonjourServices` 許可リストに
//  対して行われ、ゲスト側の宣言はマージされない。LiveContainer の許可リストに
//  `_FC9F5ED42C8A._tcp` が無いため拒否されていた。
//  (Local Network や写真ライブラリの「権限」自体はゲストでも取得できる。
//   LocalSend が LiveContainer 上で動くのは `_http._tcp` が許可リストにあり、
//   かつ Bonjour に依存しない HTTP スキャン経路を持っているため)
//  SideStore で直接インストールしたところ、初版のコード (末尾ドット無し、
//  NSBonjourServices も 1 件のみ) のまま問題なく publish できた。
//  LiveContainer 上で動かしたい場合は docs/LiveContainer-patch.md を参照。
//
//  ## 残してある診断機能
//
//    1. サービスタイプの末尾ドット切り替え
//       (`_FC9F5ED42C8A._tcp.` / `_FC9F5ED42C8A._tcp`) — どちらでも動く
//    2. publish のバックエンド 2 系統 — どちらでも動く
//       - NetService  (QuickDrop と同じ、旧 API)
//       - NWListener  (Network.framework 内蔵の Bonjour publish)
//    3. エラーコードを定数名に変換してログに出す
//    4. state の更新順序 (失敗しても "publish 済み" と出ないように)
//

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class QuickShareAdvertiser: NSObject, ObservableObject {

    /// mDNS を publish する手段。
    enum Backend: String, CaseIterable, Identifiable {
        case netService = "NetService"
        case nwListener = "NWListener"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case idle
        case starting
        case listening(port: UInt16)
        case published(port: UInt16, instanceName: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var inboundConnectionCount: Int = 0

    /// 着信した TCP 接続の受け渡し先 (M1 で追加)。
    /// nil の場合は従来どおり即座に閉じる。
    var onInboundConnection: ((NWConnection) -> Void)?

    /// 自分自身を探索結果から除外するための、現在広告中のインスタンス名。
    @Published private(set) var currentInstanceName: String?

    /// Samsung の LAN リゾルバ対策として TXT に `IPv4` / `f` を足すかどうか。
    @Published var includeExtraTxtKeys: Bool = true

    /// サービスタイプの末尾ドット。実測ではどちらでも動く (診断用に残置)。
    @Published var serviceTypeForm: QuickShareMdns.ServiceTypeForm = .withTrailingDot

    /// publish の実装系統。
    @Published var backend: Backend = .netService

    private var listener: NWListener?
    private var netService: NetService?
    private var endpointId: [UInt8] = QuickShareMdns.randomEndpointId()

    var deviceName: String = EndpointInfo.clampName(UIDeviceNameProvider.currentName())

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else {
            qlog(.warn, "Advertiser: すでに起動しています")
            return
        }
        state = .starting
        endpointId = QuickShareMdns.randomEndpointId()

        let type = serviceTypeForm.value
        qlog(.info, "Advertiser: 起動 (backend=\(backend.rawValue), type=\"\(type)\", name=\"\(deviceName)\")")

        do {
            let parameters = NWParameters(tls: .none)
            parameters.includePeerToPeer = false

            let newListener = try NWListener(using: parameters)

            if backend == .nwListener {
                // NWListener 自身に Bonjour publish もさせる
                newListener.service = NWListener.Service(
                    name: QuickShareMdns.instanceName(endpointId: endpointId),
                    type: type,
                    domain: nil,
                    txtRecord: buildTxtRecordData()
                )
                newListener.serviceRegistrationUpdateHandler = { change in
                    switch change {
                    case .add(let endpoint):
                        qlog(.ok, "Advertiser: ★ NWListener が publish しました — \(endpoint)")
                    case .remove(let endpoint):
                        qlog(.info, "Advertiser: NWListener の publish が外れました — \(endpoint)")
                    @unknown default:
                        break
                    }
                }
            }

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

    func stop() {
        netService?.stop()
        netService = nil
        listener?.cancel()
        listener = nil
        currentInstanceName = nil
        state = .idle
        qlog(.info, "Advertiser: 停止しました")
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
            if backend == .netService {
                publishWithNetService(port: port)
            } else {
                state = .published(
                    port: port,
                    instanceName: QuickShareMdns.instanceName(endpointId: endpointId)
                )
            }

        case .failed(let error):
            let message = "NWListener failed — \(describe(error))"
            qlog(.error, "Advertiser: \(message)")
            state = .failed(message)

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
        let type = serviceTypeForm.value

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
