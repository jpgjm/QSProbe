//
//  ContentView.swift
//  QSProbe
//
//  画面構成:
//    ① 受信 — 広告のオン/オフ、確認 PIN、受信の進捗
//    ② 送信 — 送るものの選択、送信の進捗、QR ペアリング
//    ③ 近くのデバイス — 探索のオン/オフ、見つかった相手 (タップで送信)
//    ④ 診断 — フレーム履歴、埋め込み設定、ログ
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var advertiser = QuickShareAdvertiser()
    @StateObject private var browser = QuickShareBrowser()
    @StateObject private var session = InboundSession()
    @StateObject private var outbound = OutboundSession()
    @StateObject private var logStore = DiagnosticLog.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var shareItems: [Any]?
    @State private var didSetUp = false

    // トグルの状態はアプリを終了しても保つ。
    // 意図 (isEnabled) は実行時の値なので、起動のたびにここから復元する。
    @AppStorage("QSProbe.receiveEnabled") private var receiveEnabled = false
    @AppStorage("QSProbe.browseEnabled") private var browseEnabled = false

    // --- 送信 ---
    @State private var pendingItems: [PendingItem] = []
    @State private var textToSend: String = ""
    @State private var showingImporter = false
    @State private var importerPicksFolder = false
    @State private var showingPhotoPicker = false
    @AppStorage("QSProbe.includeLivePhotoVideo") private var includeLivePhotoVideo = true
    @AppStorage("QSProbe.includeRootFolderName") private var includeRootFolderName = true

    // --- QR (送信側) ---
    @State private var qrKeyPair: QrKeyPair?
    @State private var qrUrlText: String?
    @AppStorage("QSProbe.qrAutoSend") private var qrAutoSend = false
    @State private var qrAutoSentPeerId: String?

    var body: some View {
        NavigationStack {
            List {
                receiveSection
                sendSection
                peersSection
                diagnosticsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("QSProbe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            shareLog()
                        } label: {
                            Label("ログを共有", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            logStore.clear()
                        } label: {
                            Label("ログを消去", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: shareSheetBinding) {
                if let shareItems {
                    ActivityView(items: shareItems)
                }
            }
            .sheet(isPresented: $showingPhotoPicker) {
                PhotoPicker(includeLivePhotoVideo: includeLivePhotoVideo) { urls in
                    showingPhotoPicker = false
                    guard !urls.isEmpty else { return }
                    let items = urls.map {
                        PendingItem(url: $0, parentFolder: "", isTemporary: true, scope: nil)
                    }
                    pendingItems.append(contentsOf: items)
                    logPendingItems(items, source: "写真・動画")
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: importerPicksFolder ? [.folder] : [.item],
                allowsMultipleSelection: !importerPicksFolder
            ) { result in
                if importerPicksFolder {
                    handleFolderPick(result)
                } else {
                    handleFilePick(result)
                }
            }
        }
        .onAppear(perform: setUpOnce)
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onChange(of: advertiser.currentInstanceName) { newValue in
            browser.selfInstanceName = newValue
        }
        .onChange(of: browser.qrMatchedPeer) { peer in
            handleQrMatchChanged(peer)
        }
    }

    // MARK: - ログの共有

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareItems != nil },
            set: { isPresented in
                if !isPresented { shareItems = nil }
            }
        )
    }

    /// `.txt` と `.jsonl` をまとめた zip を共有する。
    private func shareLog() {
        guard let url = logStore.logArchiveForSharing() else {
            qlog(.warn, "ログをまとめられませんでした")
            return
        }
        shareItems = [url]
    }

    /// アプリの前面/背面の切り替えに追従する。
    ///
    /// iOS はバックグラウンドへ回ると listener も Bonjour の publish も落とすため、
    /// 前面に戻ったときに黙って止まったままになる。トグルがオンのままなら
    /// **ユーザーの意図は続いている**ので、ここで自動的に張り直す。
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            advertiser.isForeground = true
            browser.isForeground = true
            advertiser.refresh(reason: "前面に戻った")
            browser.refresh(reason: "前面に戻った")
        case .inactive, .background:
            advertiser.isForeground = false
            browser.isForeground = false
        @unknown default:
            break
        }
    }

    private func setUpOnce() {
        guard !didSetUp else { return }
        didSetUp = true

        let target = session
        advertiser.onInboundConnection = { connection in
            Task { @MainActor in
                target.handle(connection: connection)
            }
        }

        qlog(.info, "==== QSProbe 起動 ====")
        BundleDiagnostics.dumpToLog()
        Outbox.purge()

        // 前回の状態を復元する
        if receiveEnabled {
            qlog(.info, "前回の設定を復元: 受信をオンにします")
            advertiser.setEnabled(true)
        }
        if browseEnabled {
            qlog(.info, "前回の設定を復元: 探索をオンにします")
            browser.setEnabled(true)
        }
    }

    // MARK: - ① 受信

    private var receiveSection: some View {
        Section {
            Toggle("このデバイスを見えるようにする", isOn: advertisingBinding)

            if advertiser.isEnabled {
                switch advertiser.state {
                case .published(let port, _):
                    statusRow(title: "状態", value: "待機中 (ポート \(port))", color: .green)
                case .failed:
                    statusRow(title: "状態", value: "再接続しています…", color: .orange)
                default:
                    statusRow(title: "状態", value: "準備中…", color: .orange)
                }
            }

            Toggle("確認せずに受け取る", isOn: $session.autoAcceptEnabled)

            if session.autoAcceptEnabled {
                warningText("同じ Wi-Fi 上のどの端末からでも、確認なしで受け取ります。"
                            + "送信元を限定する手段は現時点でありません。")
            }

            if session.stage != .idle {
                sessionDetail
            }
        } header: {
            Text("受信")
        } footer: {
            Text("オンの間だけ、相手の Quick Share に表示されます。"
                 + "受け取ったファイルは「ファイル」App の QSProbe → Received に入ります。")
        }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        statusRow(title: "状態", value: session.stage.rawValue, color: sessionStageColor)

        if let name = session.peerDeviceName {
            statusRow(title: "送信元", value: name, color: .green)
        }

        if let pin = session.pinCode {
            pinRow(pin, color: .green)
        }

        if session.lastTransferWasAutoAccepted {
            Label("確認なしで受け入れました", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if let error = session.lastError {
            statusRow(title: "エラー", value: error, color: .red)
        }

        ForEach(session.files) { file in
            transferRow(
                title: file.displayPath,
                done: file.isComplete,
                progress: file.progress,
                detail: "\(byteText(file.receivedBytes)) / \(byteText(file.totalSize))"
            )
            .id("in-\(file.payloadId)-\(session.progressTick)")
        }

        if session.hasPendingConsent {
            HStack {
                Button {
                    session.accept()
                } label: {
                    Label("受け取る", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button(role: .destructive) {
                    session.reject()
                } label: {
                    Label("拒否", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }

        ForEach(session.texts) { text in
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title)
                    .font(.system(size: 14, weight: .medium))
                Text(text.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - ② 送信

    private var sendSection: some View {
        Section {
            HStack(spacing: 10) {
                pickerButton("ファイル", systemImage: "doc") {
                    importerPicksFolder = false
                    showingImporter = true
                }
                pickerButton("フォルダ", systemImage: "folder") {
                    importerPicksFolder = true
                    showingImporter = true
                }
                pickerButton("写真・動画", systemImage: "photo") {
                    PhotoLibraryAccess.request { _ in
                        showingPhotoPicker = true
                    }
                }
            }
            .padding(.vertical, 2)
            .disabled(outbound.isBusy)

            textFieldRow

            if !pendingItems.isEmpty {
                pendingList
            }

            if outbound.stage != .idle {
                outboundDetail
            }

            qrRow
        } header: {
            Text("送信")
        } footer: {
            Text("送るものを選んでから、下の一覧で相手をタップします。"
                 + "相手が見つからないときは QR を表示してください。")
        }
    }

    private var textFieldRow: some View {
        HStack(spacing: 8) {
            TextField("テキストを送る", text: $textToSend, axis: .vertical)
                .lineLimit(1...4)
                .disabled(outbound.isBusy)

            if textToSend.isEmpty {
                Button {
                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                        textToSend = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .disabled(outbound.isBusy)
                .accessibilityLabel("貼り付け")
            } else {
                Button {
                    textToSend = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(outbound.isBusy)
                .accessibilityLabel("消去")
            }
        }
    }

    @ViewBuilder
    private var pendingList: some View {
        statusRow(
            title: "送るもの",
            value: "\(pendingItems.count) 件 / \(byteText(max(0, pendingTotalBytes)))",
            color: .blue
        )

        ForEach(pendingItems.prefix(10)) { item in
            Text(item.displayPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if pendingItems.count > 10 {
            Text("… ほか \(pendingItems.count - 10) 件")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        Button(role: .destructive) {
            clearPendingItems()
        } label: {
            Label("選択を解除", systemImage: "xmark.circle")
        }
        .disabled(outbound.isBusy)

        DisclosureGroup("送信のオプション") {
            Toggle("フォルダ名も相手に残す", isOn: $includeRootFolderName)
            Toggle("Live Photo は動画も送る", isOn: $includeLivePhotoVideo)
        }
        .disabled(outbound.isBusy)
    }

    @ViewBuilder
    private var outboundDetail: some View {
        statusRow(title: "状態", value: outbound.stage.rawValue, color: outboundStageColor)

        if let target = outbound.targetName {
            statusRow(title: "送信先", value: target, color: .secondary)
        }

        if let pin = outbound.pinCode {
            pinRow(pin, color: .blue)
        }

        if let error = outbound.lastError {
            statusRow(title: "エラー", value: error, color: .red)
        }

        ForEach(outbound.files) { file in
            transferRow(
                title: file.displayPath,
                done: file.isComplete,
                progress: file.progress,
                detail: "\(byteText(file.sentBytes)) / \(byteText(file.totalSize))"
            )
            .id("out-\(file.payloadId)-\(outbound.progressTick)")
        }

        if outbound.isBusy {
            Button(role: .destructive) {
                outbound.cancel()
            } label: {
                Label("送信を中止", systemImage: "stop.circle")
            }
        } else {
            Button {
                outbound.reset()
            } label: {
                Label("送信の表示を消す", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - QR (送信側)

    @ViewBuilder
    private var qrRow: some View {
        if let qrUrlText {
            VStack(alignment: .leading, spacing: 10) {
                Text("この QR を相手のカメラで読み取ってもらってください")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    QrCodeView(text: qrUrlText)
                    Spacer()
                }

                if let peer = browser.qrMatchedPeer {
                    Label(
                        "見つかりました: \(browser.qrMatchedName ?? peer.displayName)",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)

                    if !qrAutoSend {
                        Button {
                            sendViaQr(to: peer)
                        } label: {
                            Label("この相手に送信", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                    }
                } else {
                    Label("相手の読み取りを待っています…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            Toggle("読み取られたら自動で送信", isOn: $qrAutoSend)

            Button(role: .destructive) {
                stopQrDisplay()
            } label: {
                Label("QR を閉じる", systemImage: "xmark.circle")
            }
        } else {
            Button {
                startQrDisplay()
            } label: {
                Label("QR を表示して送る", systemImage: "qrcode")
            }
            .disabled(outbound.isBusy)
        }
    }

    // MARK: - ③ 近くのデバイス

    private var peersSection: some View {
        Section {
            Toggle("近くのデバイスを探す", isOn: browsingBinding)

            if browser.isEnabled {
                if case .failed = browser.state {
                    statusRow(title: "状態", value: "再接続しています…", color: .orange)
                } else if browser.peers.isEmpty {
                    Text("探しています…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(browser.peers) { peer in
                        peerRow(peer)
                    }
                }
            }
        } header: {
            Text("近くのデバイス")
        } footer: {
            Text("相手側で Quick Share の受信画面を開いておく必要があります。"
                 + "送るものを選ぶと、タップで送信できるようになります。")
        }
    }

    private func peerRow(_ peer: DiscoveredPeer) -> some View {
        Button {
            outbound.send(
                items: pendingItems,
                text: textToSend.isEmpty ? nil : textToSend,
                to: peer.endpoint,
                peerName: peer.displayName
            )
        } label: {
            HStack {
                Image(systemName: icon(for: peer.deviceType))
                    .foregroundStyle(canSend ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.body.weight(.medium))
                    Text(String(describing: peer.deviceType))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if canSend {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .disabled(!canSend)
        .padding(.vertical, 2)
    }

    private func icon(for type: DeviceType) -> String {
        switch type {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }

    // MARK: - ④ 診断

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("受信したフレーム (\(session.summaries.count))") {
                if session.summaries.isEmpty {
                    Text("まだありません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.summaries) { summary in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if summary.isEncrypted {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Text("#\(summary.index)  \(summary.kind)  (\(summary.byteCount) バイト)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            Text(summary.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button(role: .destructive) {
                    session.reset()
                } label: {
                    Label("受信の表示を消す", systemImage: "arrow.counterclockwise")
                }
            }

            DisclosureGroup("埋め込み設定") {
                statusRow(title: "Bundle ID", value: BundleDiagnostics.bundleIdentifier, color: .secondary)
                statusRow(
                    title: "ローカルネットワーク",
                    value: BundleDiagnostics.localNetworkUsageDescription == nil ? "✗ 欠落" : "○ 有り",
                    color: BundleDiagnostics.localNetworkUsageDescription == nil ? .red : .green
                )
                if let services = BundleDiagnostics.bonjourServices, !services.isEmpty {
                    ForEach(services, id: \.self) { service in
                        statusRow(title: "Bonjour", value: service, color: .green)
                    }
                } else {
                    statusRow(title: "Bonjour", value: "✗ 欠落", color: .red)
                }

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("この App の設定を開く", systemImage: "gearshape")
                }
            }

            DisclosureGroup("ログ (\(logStore.entries.count))") {
                if logStore.entries.isEmpty {
                    Text("まだありません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logStore.entries.reversed().prefix(200)) { entry in
                        Text(entry.formatted)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("診断")
        } footer: {
            Text("右上のメニューから共有すると、テキストと JSON Lines を"
                 + "まとめた zip を書き出します。")
        }
    }

    // MARK: - トグルのバインディング

    // トグルは「実際に動いているか」ではなく**ユーザーの意図**に結び付ける。
    // 実状態に結び付けると、バックグラウンド復帰で勝手にオフに見えてしまう。
    private var advertisingBinding: Binding<Bool> {
        Binding(
            get: { advertiser.isEnabled },
            set: { isOn in
                receiveEnabled = isOn
                advertiser.setEnabled(isOn)
            }
        )
    }

    private var browsingBinding: Binding<Bool> {
        Binding(
            get: { browser.isEnabled },
            set: { isOn in
                browseEnabled = isOn
                browser.setEnabled(isOn)
            }
        )
    }

    // MARK: - QR の操作

    private func startQrDisplay() {
        guard let pair = QrKeyPair.generate() else {
            qlog(.error, "QR: 鍵ペアの生成に失敗しました")
            return
        }
        qrKeyPair = pair
        qrUrlText = QrUrl.build(pair.keyData)
        browser.qrKeys = QrKeyDerivation.deriveKeys(pair.keyData)
        qlog(.ok, "QR: ★ 送信用の QR を表示しました")
        if !browser.isEnabled {
            browseEnabled = true
            browser.setEnabled(true)
        }
    }

    private func stopQrDisplay() {
        qrKeyPair = nil
        qrUrlText = nil
        browser.qrKeys = nil
        qrAutoSentPeerId = nil
        qlog(.info, "QR: 送信用の QR を閉じました")
    }

    private func handleQrMatchChanged(_ peer: DiscoveredPeer?) {
        guard let peer else {
            qrAutoSentPeerId = nil
            return
        }
        guard qrAutoSend else { return }
        guard qrAutoSentPeerId != peer.id else { return }
        guard canSend else {
            qlog(.warn, "QR: 自動送信が有効ですが、送るものが選ばれていません")
            return
        }
        guard !outbound.isBusy else { return }

        qrAutoSentPeerId = peer.id
        qlog(.warn, "QR: ⚠ 自動送信が有効なため、確認なしで送信を始めます")
        qlog(.warn, "QR:   宛先 = \(browser.qrMatchedName ?? peer.displayName)")
        sendViaQr(to: peer)
    }

    private func sendViaQr(to peer: DiscoveredPeer) {
        outbound.send(
            items: pendingItems,
            text: textToSend.isEmpty ? nil : textToSend,
            to: peer.endpoint,
            peerName: browser.qrMatchedName ?? peer.displayName,
            qrKeyPair: qrKeyPair
        )
    }

    // MARK: - 送信候補の操作

    private var canSend: Bool {
        !outbound.isBusy && (!pendingItems.isEmpty || !textToSend.isEmpty)
    }

    private var pendingTotalBytes: Int64 {
        pendingItems.reduce(Int64(0)) { $0 + fileSize(of: $1.url) }
    }

    /// 読めなければ -1 を返す。0 と「読めなかった」を区別するため。
    private func fileSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return -1
        }
        return size
    }

    /// 送信候補に追加したものをログに残す。
    ///
    /// 一覧の合計が `Zero KB` になる事象があったが、原因が握り潰されていて
    /// 追えなかった。ここでサイズを個別に出し、読めなかったものは明示する。
    private func logPendingItems(_ items: [PendingItem], source: String) {
        var total: Int64 = 0
        var unreadable = 0

        qlog(.info, "送信候補に\(source) \(items.count) 件を追加しました")
        for item in items.prefix(20) {
            let size = fileSize(of: item.url)
            if size < 0 {
                unreadable += 1
                qlog(.warn, "  ✗ \(item.displayPath) — サイズを読めません")
                qlog(.warn, "     path = \(item.url.path)")
            } else {
                total += size
                qlog(.info, "  \(item.displayPath) — \(size) バイト")
            }
        }
        if items.count > 20 {
            qlog(.info, "  … ほか \(items.count - 20) 件")
            for item in items.dropFirst(20) {
                let size = fileSize(of: item.url)
                if size < 0 { unreadable += 1 } else { total += size }
            }
        }

        qlog(.info, "  合計 \(total) バイト" + (unreadable > 0 ? " / 読めなかったもの \(unreadable) 件" : ""))
        if unreadable > 0 {
            qlog(.warn, "  → 一覧の合計が小さく見えるのはこれが原因です")
        }
    }

    private func clearPendingItems() {
        for item in pendingItems where item.isTemporary {
            try? FileManager.default.removeItem(at: item.url)
        }
        pendingItems = []
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let items = urls.map {
                PendingItem(
                    url: $0,
                    parentFolder: "",
                    isTemporary: false,
                    scope: SecurityScope(url: $0)
                )
            }
            pendingItems.append(contentsOf: items)
            logPendingItems(items, source: "ファイル")
        case .failure(let error):
            qlog(.warn, "ファイル選択に失敗: \(error)")
        }
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            let includeRoot = includeRootFolderName
            qlog(.info, "フォルダ \(folder.lastPathComponent) を走査しています…")
            DispatchQueue.global(qos: .userInitiated).async {
                let items = FolderScanner.scan(folder: folder, includeRootName: includeRoot)
                DispatchQueue.main.async {
                    pendingItems.append(contentsOf: items)
                    logPendingItems(items, source: "フォルダ \(folder.lastPathComponent)")
                }
            }
        case .failure(let error):
            qlog(.warn, "フォルダ選択に失敗: \(error)")
        }
    }

    // MARK: - 共通の部品

    private func pickerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }

    private func transferRow(
        title: String,
        done: Bool,
        progress: Double,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            ProgressView(value: progress)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func pinRow(_ pin: String, color: Color) -> some View {
        HStack {
            Text("確認コード")
                .font(.subheadline)
            Spacer()
            Text(pin)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func warningText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }

    private var sessionStageColor: Color {
        switch session.stage {
        case .completed: return .green
        case .receiving, .awaitingConsent: return .blue
        case .encrypted, .receivedClientFinish: return .green
        case .failed: return .red
        case .idle, .closed, .rejected: return .secondary
        default: return .orange
        }
    }

    private var outboundStageColor: Color {
        switch outbound.stage {
        case .completed: return .green
        case .sending, .sentIntroduction: return .blue
        case .failed: return .red
        case .idle, .closed, .rejected: return .secondary
        default: return .orange
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 共有シート

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
