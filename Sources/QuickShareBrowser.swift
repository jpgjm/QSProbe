//
//  QuickShareBrowser.swift
//  QSProbe
//
//  M0 のもう一つの検証項目:
//    「`NSBonjourServices` を Info.plist に書いただけで、multicast
//      entitlement 無しに NWBrowser が Quick Share ピアを拾えるか」
//
//  Android 側で Quick Share の受信画面 (「全ユーザーに表示」など) を
//  開いた状態にすると、mDNS レコードが publish されるので、それが
//  ここに出てくれば成功。
//

import Foundation
import Network

struct DiscoveredPeer: Identifiable, Equatable {
    let id: String            // インスタンス名 (mDNS のサービス名)
    let deviceName: String?
    let deviceType: DeviceType
    let hidden: Bool
    let endpointDescription: String
    let rawEndpointInfo: String?
    /// 送信時に `NWConnection(to:)` へ渡すエンドポイント (M4 で追加)。
    /// Bonjour の名前解決は Network.framework が面倒を見てくれる。
    let endpoint: NWEndpoint

    var displayName: String {
        hidden ? "(hidden)" : (deviceName ?? "(名前なし)")
    }
}

@MainActor
final class QuickShareBrowser: ObservableObject {

    enum State: Equatable {
        case idle
        case browsing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var peers: [DiscoveredPeer] = []

    private var browser: NWBrowser?

    /// サービスタイプの末尾ドット。実測ではどちらでも動く (診断用に残置)。
    @Published var serviceTypeForm: QuickShareMdns.ServiceTypeForm = .withTrailingDot

    /// 自分自身の広告を一覧から除外する (M1 で追加)。
    /// Advertiser が publish 中のインスタンス名をここに反映する。
    @Published var selfInstanceName: String?

    /// 自己除外を有効にするか。切り分け用にトグルできる。
    @Published var excludeSelf: Bool = true

    func start() {
        guard browser == nil else {
            qlog(.warn, "Browser: すでに起動しています")
            return
        }
        let type = serviceTypeForm.value
        qlog(.info, "Browser: 探索を開始します (type=\"\(type)\")")

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: type, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.handleState(newState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleResults(results, changes: changes)
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers.removeAll()
        state = .idle
        qlog(.info, "Browser: 停止しました")
    }

    // MARK: - Handlers

    private func handleState(_ newState: NWBrowser.State) {
        switch newState {
        case .setup:
            qlog(.info, "Browser: setup")
        case .ready:
            state = .browsing
            qlog(.ok, "Browser: ★ 探索を開始しました (ready)")
        case .waiting(let error):
            // ローカルネットワーク権限が拒否されているとここに来ることが多い
            qlog(.warn, "Browser: waiting — \(describe(error))")
        case .failed(let error):
            let message = describe(error)
            qlog(.error, "Browser: ✗ failed — \(message)")
            if case let .dns(code) = error, Int(code) == -65555 {
                qlog(.warn, "Browser: → ローカルネットワーク権限が下りていません。"
                    + "設定 > プライバシーとセキュリティ > ローカルネットワーク を確認してください。"
                    + "一覧に QSProbe が出ていない場合は Info.plist 側の問題です。")
            }
            state = .failed(message)
        case .cancelled:
            qlog(.info, "Browser: cancelled")
        @unknown default:
            break
        }
    }

    private func handleResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                qlog(.ok, "Browser: ★ 発見 \(describe(result))")
            case .removed(let result):
                qlog(.info, "Browser: 消失 \(describe(result))")
            case .changed(old: _, new: let result, flags: _):
                qlog(.info, "Browser: 更新 \(describe(result))")
            default:
                break
            }
        }
        peers = results.compactMap { makePeer(from: $0) }
            .filter { peer in
                guard excludeSelf, let selfName = selfInstanceName else { return true }
                return peer.id != selfName
            }
            .sorted { ($0.deviceName ?? $0.id) < ($1.deviceName ?? $1.id) }
    }

    /// NWError を定数名つきで文字列化する。
    private func describe(_ error: NWError) -> String {
        if case let .dns(code) = error {
            return "\(error) [\(NetErrorNames.dnssd(Int(code)))]"
        }
        return "\(error)"
    }

    // MARK: - Parsing

    private func serviceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint {
            return name
        }
        return nil
    }

    private func endpointInfoString(_ result: NWBrowser.Result) -> String? {
        guard case let .bonjour(txtRecord) = result.metadata else { return nil }
        return txtRecord[QuickShareMdns.txtKeyEndpointInfo]
    }

    private func makePeer(from result: NWBrowser.Result) -> DiscoveredPeer? {
        guard let name = serviceName(result) else { return nil }
        let encoded = endpointInfoString(result)
        var deviceName: String?
        var deviceType: DeviceType = .unknown
        var hidden = false

        if let encoded,
           let raw = Base64Url.decode(encoded),
           let info = EndpointInfo.parse(raw) {
            deviceName = info.deviceName
            deviceType = info.deviceType
            hidden = info.hidden
        }

        return DiscoveredPeer(
            id: name,
            deviceName: deviceName,
            deviceType: deviceType,
            hidden: hidden,
            endpointDescription: "\(result.endpoint)",
            rawEndpointInfo: encoded,
            endpoint: result.endpoint
        )
    }

    private func describe(_ result: NWBrowser.Result) -> String {
        let name = serviceName(result) ?? "?"
        if let encoded = endpointInfoString(result),
           let raw = Base64Url.decode(encoded),
           let info = EndpointInfo.parse(raw) {
            let displayName = info.hidden ? "(hidden)" : (info.deviceName ?? "(no name)")
            return "\(displayName) [type=\(info.deviceType), v=\(info.version)] name=\(name)"
        }
        return "name=\(name) (EndpointInfo をパースできず)"
    }
}
