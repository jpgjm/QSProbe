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
    /// QR 照合に使う EndpointInfo (M7 で追加)。パースできなかった場合は nil。
    let endpointInfo: EndpointInfo?

    /// 広告に載っている暗号化 metadata 鍵が、手元の証明書のどれかと合ったか。
    ///
    /// **これは「本人確認」ではない。** 広告は誰でもそのままコピーして
    /// 流せるので、同じ 16 バイトを名乗ることはできる。示せるのは
    /// 「登録済みの端末が出す広告と同じものを出している」までで、
    /// 相手が本人かどうかは接続して署名を検証するまで分からない。
    let knownCertificate: Bool

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

    /// ユーザーが「探す」を望んでいるか。実際の `state` とは別に持つ。
    /// バックグラウンド復帰時に自動で張り直すための意図の記録。
    @Published private(set) var isEnabled = false

    @Published private(set) var state: State = .idle
    @Published private(set) var peers: [DiscoveredPeer] = []

    /// アプリが前面にいるか。
    var isForeground = true

    /// 無音再生でプロセスが生きたまま保たれているか (`BackgroundKeepAlive`)。
    ///
    /// これが真なら、背面へ回っても NWBrowser は落ちない。落ちたならそれは
    /// 「サスペンドされた」ではなく本物の失敗なので、背面でも再試行するし
    /// ログのレベルも下げない。ContentView が実状態を書き込む。
    var staysAliveInBackground = false

    /// 再試行してよい状況か。失敗をエラーとして扱うかの判定も兼ねる。
    ///
    /// 前面にいるか、無音再生で起きたままかのどちらか。背面でサスペンドされる
    /// 前提のときだけ「これは障害ではない」と見なす。
    private var isAwake: Bool { isForeground || staysAliveInBackground }

    private var retryScheduled = false

    private var browser: NWBrowser?

    /// 自分自身の広告を一覧から除外する (M1 で追加)。
    /// Advertiser が publish 中のインスタンス名をここに反映する。
    @Published var selfInstanceName: String?

    /// 自己除外を有効にするか。切り分け用にトグルできる。
    @Published var excludeSelf: Bool = true

    /// QR 送信モードで照合に使う鍵。設定すると `qrMatchedPeer` が埋まる。
    @Published var qrKeys: DerivedQrKeys? {
        didSet { updateQrMatch() }
    }

    /// 自分が出している QR を読み取った相手。見つかっていなければ nil。
    @Published private(set) var qrMatchedPeer: DiscoveredPeer?
    /// hidden モードで復号できたデバイス名。
    @Published private(set) var qrMatchedName: String?

    /// トグルの操作。
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            beginBrowsing()
        } else {
            endBrowsing()
            qlog(.info, "Browser: 停止しました")
        }
    }

    /// 前面復帰時などに呼ぶ。意図がオンなのに動いていなければ張り直す。
    func refresh(reason: String) {
        guard isEnabled else { return }
        guard state != .browsing || browser == nil else { return }
        qlog(.info, "Browser: \(reason)ため再開します")
        endBrowsing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.beginBrowsing()
        }
    }

    func start() {
        isEnabled = true
        beginBrowsing()
    }

    func stop() {
        isEnabled = false
        endBrowsing()
        qlog(.info, "Browser: 停止しました")
    }

    private func scheduleRetry(_ reason: String) {
        guard isEnabled, isAwake, !retryScheduled else { return }
        retryScheduled = true
        qlog(.info, "Browser: \(reason) — 2 秒後に再試行します")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.refresh(reason: "前回の失敗から復帰する")
        }
    }

    private func beginBrowsing() {
        guard browser == nil else {
            qlog(.warn, "Browser: すでに起動しています")
            return
        }
        let type = QuickShareMdns.serviceType
        qlog(.info, "Browser: 探索を開始します")

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

    private func endBrowsing() {
        browser?.cancel()
        browser = nil
        peers.removeAll()
        state = .idle
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
            // 背面にいるあいだの失敗は、iOS がサスペンド時に NWBrowser を
            // 落としたことの通知でしかない。前面に戻れば refresh が張り直す。
            // 失敗の配送は前面復帰の直前に来るので、この時点の isForeground は
            // まだ false になっている。
            // 無音再生で起きたままのときは、そもそも切れないはずなので本物の失敗。
            if isAwake {
                qlog(.error, "Browser: ✗ failed — \(message)")
            } else {
                qlog(.info, "Browser: サスペンドで探索が切れました — \(message)。"
                    + "前面復帰時に張り直します")
            }
            scheduleRetry("探索が落ちました")
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
        updateQrMatch()
    }

    /// NWError を定数名つきで文字列化する。
    private func describe(_ error: NWError) -> String {
        if case let .dns(code) = error {
            return "\(error) [\(NetErrorNames.dnssd(Int(code)))]"
        }
        return "\(error)"
    }

    /// QR 送信モードで、一覧の中に自分の QR を読んだ相手がいるかを調べる。
    private func updateQrMatch() {
        guard let qrKeys else {
            if qrMatchedPeer != nil {
                qrMatchedPeer = nil
                qrMatchedName = nil
            }
            return
        }

        for peer in peers {
            guard let info = peer.endpointInfo else { continue }
            switch QrTlvMatcher.match(endpointInfo: info, keys: qrKeys) {
            case .visible:
                if qrMatchedPeer?.id != peer.id {
                    qlog(.ok, "Browser: ★★ QR 照合成功 (visible) — \(peer.displayName)")
                }
                qrMatchedPeer = peer
                qrMatchedName = peer.deviceName
                return
            case .hidden(let name):
                if qrMatchedPeer?.id != peer.id {
                    qlog(.ok, "Browser: ★★ QR 照合成功 (hidden) — 復号したデバイス名 = \(name)")
                }
                qrMatchedPeer = peer
                qrMatchedName = name
                return
            case .noMatch:
                continue
            }
        }

        if qrMatchedPeer != nil {
            qlog(.info, "Browser: QR 照合していた相手が消えました")
            qrMatchedPeer = nil
            qrMatchedName = nil
        }
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
        var parsed: EndpointInfo?

        if let encoded,
           let raw = Base64Url.decode(encoded),
           let info = EndpointInfo.parse(raw) {
            deviceName = info.deviceName
            deviceType = info.deviceType
            hidden = info.hidden
            parsed = info
        }

        return DiscoveredPeer(
            id: name,
            deviceName: deviceName,
            deviceType: deviceType,
            hidden: hidden,
            endpointDescription: "\(result.endpoint)",
            rawEndpointInfo: encoded,
            endpoint: result.endpoint,
            endpointInfo: parsed,
            knownCertificate: Self.matchesKnownCertificate(parsed)
        )
    }

    /// 広告の 16 バイトが、手元の証明書のどれかと合うか。
    ///
    /// 実験機能がオフか、証明書を持っていなければ常に false。
    private static func matchesKnownCertificate(_ info: EndpointInfo?) -> Bool {
        guard let info, info.metadata.count >= 16 else { return false }
        guard AccountStore.shared.isEnabled else { return false }
        let pool = CertificateStore.shared.certificates.map { $0.certificate }
        guard !pool.isEmpty else { return false }
        return AdvertisementIdentity.identify(metadata: info.metadata, certificates: pool) != nil
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
