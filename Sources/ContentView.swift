//
//  ContentView.swift
//  QSProbe
//
//  画面構成:
//    ① 受信 — 広告のオン/オフ、確認 PIN、受信の進捗
//    ② 送信 — 送るものの選択、送信の進捗、QR ペアリング
//    ③ 近くのデバイス — 探索のオン/オフ、見つかった相手 (タップで送信)
//    ④ 診断 — フレーム履歴、埋め込み設定、ログ
//    ⑤ 実験機能 — アカウント連携 (既定でオフ / Sources/Account/)
//

import SwiftUI
import Photos
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var advertiser = QuickShareAdvertiser()
    @StateObject private var browser = QuickShareBrowser()
    @StateObject private var session = InboundSession()
    @StateObject private var outbound = OutboundSession()
    @StateObject private var logStore = DiagnosticLog.shared
    /// 自動承認の絞り込み設定を読むために参照する。実験機能がオフなら無関係。
    @ObservedObject private var account = AccountStore.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var shareItems: [Any]?
    /// コピー直後に印を出すための、対象テキストの id。
    @State private var copiedTextId: UUID?
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

    /// 探し始めてからの秒数。空の表示を出し分けるためだけに使う。
    @State private var browseStartedAt: Date?
    @State private var browseElapsed: TimeInterval = 0

    @ObservedObject private var deviceName = DeviceNameStore.shared
    /// いま広告に出ている名前。入力中の値と区別する。
    @State private var advertisedName = DeviceNameStore.shared.effectiveName

    var body: some View {
        NavigationStack {
            List {
                receiveSection
                sendSection
                peersSection
                diagnosticsSection
                // 実験機能。既定でオフ。実体は Sources/Account/ 以下にあり、
                // 既存の送受信からは独立している。状態は 1 行で示し、
                // 詳しくは別画面へ送る。
                AccountSummaryRow()
            }
            .listStyle(.insetGrouped)
            // 転送中は上に貼り付ける。スクロールしても見失わない。
            .safeAreaInset(edge: .top, spacing: 0) {
                transferBanner
            }
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
            // 同意は判断を迫る場面なので、他を触らせない。
            .sheet(isPresented: consentBinding) {
                ConsentSheet(session: session)
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
                    addPendingItems(items, source: "写真・動画")
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
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            // 空表示の出し分けだけに使う軽い時計。
            guard let started = browseStartedAt, browser.peers.isEmpty else {
                browseElapsed = 0
                return
            }
            browseElapsed = Date().timeIntervalSince(started)
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
            deviceNameRow

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

            Toggle("写真とビデオを「写真」に保存", isOn: photoLibraryBinding)

            Text(session.saveMediaToPhotos
                 ? "写真・動画は「写真」App に入ります。それ以外は「ファイル」の QSProbe → Received です。"
                 : "すべて「ファイル」の QSProbe → Received に保存されます。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("確認せずに受け取る", isOn: $session.autoAcceptEnabled)

            if session.autoAcceptEnabled {
                if account.isEnabled && account.autoAcceptVerifiedOnly {
                    warningText("署名を検証できた相手だけ、確認なしで受け取ります。"
                                + "検証できない相手からは、これまでどおり確認コードを表示します。")
                } else {
                    warningText("同じ Wi-Fi 上のどの端末からでも、確認なしで受け取ります。"
                                + "送信元を限定する手段は現時点でありません。")
                }
            }

            if session.stage != .idle, !session.hasPendingConsent {
                sessionDetail
            }
        } header: {
            Text("受信")
        } footer: {
            Text("オンの間だけ、相手の Quick Share に表示されます。")
        }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        statusRow(title: "状態", value: session.stage.rawValue, color: sessionStageColor)

        if let name = session.peerDeviceName {
            // 証明書の公開鍵で署名を検証できた相手だけ、印を付ける。
            // 名前は相手が名乗っているだけの値なので、検証の有無は区別する。
            statusRow(
                title: "送信元",
                value: session.peerVerified ? "\(name) ✓ 署名を検証済み" : name,
                color: .green
            )
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
                detail: receivedFileDetail(file)
            )
            .id("in-\(file.payloadId)-\(session.progressTick)")
        }

        ForEach(session.texts) { text in
            receivedTextRow(text)
        }
    }

    /// 進捗の下に出す説明。完了後は保存先も添える。
    private func receivedFileDetail(_ file: ReceivingFile) -> String {
        let size = "\(byteText(file.receivedBytes)) / \(byteText(file.totalSize))"
        guard file.isComplete else { return size }
        return file.destination == .photos
            ? "\(size)  ·  「写真」App"
            : "\(size)  ·  Received"
    }

    /// 受け取ったテキスト 1 件。
    ///
    /// `.textSelection(.enabled)` だけだと `List` の行では長押しが行内スクロールや
    /// セルのタップに取られて選択しづらい。確実にコピーできるよう、
    /// ボタンとコンテキストメニューの両方を用意する。
    private func receivedTextRow(_ text: ReceivedText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(text.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    copy(text)
                } label: {
                    Label(
                        copiedTextId == text.id ? "コピーしました" : "コピー",
                        systemImage: copiedTextId == text.id ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copiedTextId == text.id ? .green : .blue)

                if let url = text.openableURL {
                    Button {
                        open(url)
                    } label: {
                        Label("開く", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copy(text)
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            if let url = text.openableURL {
                Button {
                    open(url)
                } label: {
                    Label("開く", systemImage: "safari")
                }
            }
        }
    }

    private func open(_ url: URL) {
        qlog(.info, "受信した URL を開きます — \(url.absoluteString)")
        UIApplication.shared.open(url)
    }

    private func copy(_ text: ReceivedText) {
        UIPasteboard.general.string = text.body
        copiedTextId = text.id
        qlog(.ok, "受信したテキストをコピーしました (\(text.body.utf8.count) バイト)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedTextId == text.id {
                copiedTextId = nil
            }
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

        // 1 件ずつ外せるようにする。全消ししかないと、
        // 間違えて足した 1 件のために選び直すことになる。
        ForEach(pendingItems) { item in
            HStack {
                Text(item.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(byteText(fileSize(of: item.url)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    removePendingItem(item)
                } label: {
                    Label("外す", systemImage: "trash")
                }
            }
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
            .disabled(outbound.isBusy || !canSend)

            // 押せない理由を添える。無効になっているだけだと壊れて見える。
            if !canSend && !outbound.isBusy {
                Text("先に送るものを選んでください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 相手が 1 台も見つからないときの表示。
    ///
    /// 「探しています…」だけだと、始めたばかりなのか、探して見つからないのかが
    /// 区別できない。時間が経っても出てこないなら、原因の候補を示す。
    @ViewBuilder
    private var emptyPeersRow: some View {
        if browseElapsed < 6 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("探しています…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("見つかりません")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Text("相手側で Quick Share の受信画面を開いているか、"
                     + "同じ Wi-Fi につながっているかを確かめてください。"
                     + "相手が「自分のデバイスのみ」に設定していると、"
                     + "同じアカウントでなければ見えません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
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
                    emptyPeersRow
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
                peerName: peer.displayName,
                // 相手の広告を渡しておくと、送信中に証明書を特定できる。
                peerAdvertisement: peer.endpointInfo?.metadata
            )
        } label: {
            HStack {
                Image(systemName: icon(for: peer.deviceType))
                    .foregroundStyle(canSend ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(peer.displayName)
                            .font(.body.weight(.medium))
                        if peer.knownCertificate {
                            // 広告が手元の証明書と合っただけ。本人確認ではない。
                            // 広告はコピーできるので、確定するのは接続後。
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(peer.knownCertificate
                         ? "\(String(describing: peer.deviceType)) / 登録済みの端末"
                         : String(describing: peer.deviceType))
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

    /// 診断は別画面へ。普段は見ないものを一覧に混ぜない。
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(session: session, onShare: shareLog)
            } label: {
                HStack {
                    Label("診断", systemImage: "stethoscope")
                    Spacer()
                    Text("ログ \(logStore.entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「写真」への保存トグル。
    ///
    /// **オンにする時点で権限を訊く。** 受信が始まってから訊くと、
    /// 拒否されたときに受け取ったデータの行き先が無くなる。
    /// 「このデバイスを見えるようにする」と同じで、トグルの状態は
    /// **実際に保存できるか**と一致していてほしい。
    private var photoLibraryBinding: Binding<Bool> {
        Binding(
            get: { session.saveMediaToPhotos },
            set: { isOn in
                guard isOn else {
                    session.saveMediaToPhotos = false
                    return
                }
                requestPhotoLibraryAccess { granted in
                    session.saveMediaToPhotos = granted
                    if !granted {
                        qlog(.warn, "「写真」への追加が許可されなかったので、"
                            + "すべて「ファイル」に保存します")
                    }
                }
            }
        )
    }

    /// 追加のみの権限を求める。全件の読み取りは要らない。
    private func requestPhotoLibraryAccess(_ completion: @escaping (Bool) -> Void) {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            completion(true)
        case .denied, .restricted:
            qlog(.warn, "「写真」への追加が拒否されています。設定から変えてください")
            completion(false)
        default:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in
                    completion(status == .authorized || status == .limited)
                }
            }
        }
    }

    /// 相手に見せる名前。
    ///
    /// iOS 16 以降、`UIDevice.current.name` は「iPad」のような機種名しか
    /// 返さない。設定で付けた名前は取れないので、**アプリ側で持つしかない**。
    private var deviceNameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            PasteableField(
                title: "この端末の名前",
                placeholder: deviceName.systemName,
                text: $deviceName.customName
            )

            Text(deviceName.isCustomised
                 ? "相手にはこの名前で表示されます。"
                 : "空欄のときは「\(deviceName.systemName)」と表示されます。"
                   + "iOS の制限で、設定で付けた名前は読めません。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if nameNeedsRestart {
                Button {
                    applyDeviceName()
                } label: {
                    Label("名前を反映する", systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 入力した名前が、いま広告に出ている名前と食い違っているか。
    private var nameNeedsRestart: Bool {
        advertiser.isEnabled && advertisedName != deviceName.effectiveName
    }

    /// 名前を広告に反映する。
    ///
    /// 広告は起動時に組み立てるので、張り直さないと変わらない。
    /// 登録済みの場合、アカウント側の名前は証明書の中にあるので、
    /// 作り直して登録し直すまで変わらない。
    private func applyDeviceName() {
        advertisedName = deviceName.effectiveName
        advertiser.restart(reason: "名前を変えた")
        qlog(.info, "この端末の名前を「\(deviceName.effectiveName)」にしました")

        if !LocalCertificateStore.shared.certificates.isEmpty {
            qlog(.warn, "アカウントに登録した名前は、証明書を作り直して"
                + "登録し直すまで変わりません")
        }
    }

    // MARK: - 転送中の帯と同意のシート

    /// 転送中だけ画面の上に出す。受信と送信のどちらか一方だけを出す
    /// (同時に走る場面はまず無く、出しても読めない)。
    @ViewBuilder
    private var transferBanner: some View {
        if let file = session.files.first(where: { !$0.isComplete }),
           !session.hasPendingConsent {
            TransferBanner(
                title: file.displayPath,
                subtitle: "\(session.peerDeviceName ?? "受信中") — "
                    + "\(ByteFormat.short(file.receivedBytes)) / \(ByteFormat.short(file.totalSize))",
                progress: file.progress,
                isSending: false,
                onCancel: { session.cancel() }
            )
            .id("banner-in-\(file.payloadId)-\(session.progressTick)")
        } else if outbound.isBusy, let file = outbound.files.first(where: { !$0.isComplete }) {
            TransferBanner(
                title: file.displayPath,
                subtitle: "\(outbound.targetName ?? "送信中") — "
                    + "\(ByteFormat.short(file.sentBytes)) / \(ByteFormat.short(file.totalSize))",
                progress: file.progress,
                isSending: true,
                onCancel: { outbound.cancel() }
            )
            .id("banner-out-\(file.payloadId)-\(outbound.progressTick)")
        }
    }

    /// 同意待ちのあいだだけシートを出す。
    ///
    /// 閉じる操作は「拒否」と同じ意味にする。判断せずに消せると、
    /// 相手が待ち続けることになる。
    private var consentBinding: Binding<Bool> {
        Binding(
            get: { session.hasPendingConsent },
            set: { isShown in
                if !isShown, session.hasPendingConsent {
                    session.reject()
                }
            }
        )
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
                browseStartedAt = isOn ? Date() : nil
                browseElapsed = 0
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
            qrKeyPair: qrKeyPair,
            peerAdvertisement: peer.endpointInfo?.metadata
        )
    }

    // MARK: - 送信候補の操作

    /// 送信候補から 1 件外す。
    ///
    /// 一時ファイル (写真から取り出したもの) は、外した時点で消す。
    /// 残すと Outbox に溜まり続ける。
    private func removePendingItem(_ item: PendingItem) {
        if item.isTemporary {
            try? FileManager.default.removeItem(at: item.url)
        }
        pendingItems.removeAll { $0.id == item.id }
        qlog(.info, "送信候補から外しました — \(item.displayPath)")
    }

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
    /// 送信候補に足す。**同じファイルは二度入れない。**
    ///
    /// 一覧に件数は出しているが、選び直したつもりで二重に積むと、
    /// 同じものを 2 回送ってしまう。実際にそれが起きた。
    /// 同じファイルを重ねて送りたい場面は考えにくいので、ここで弾く。
    private func addPendingItems(_ items: [PendingItem], source: String) {
        let existing = Set(pendingItems.map { $0.url })
        let fresh = items.filter { !existing.contains($0.url) }
        let skipped = items.count - fresh.count

        if skipped > 0 {
            qlog(.warn, "送信候補: 既に入っている \(skipped) 件は足しませんでした")
        }
        guard !fresh.isEmpty else { return }

        pendingItems.append(contentsOf: fresh)
        logPendingItems(fresh, source: source)
        qlog(.info, "  送信候補は合計 \(pendingItems.count) 件になりました")
    }

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
            addPendingItems(items, source: "ファイル")
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
                    addPendingItems(items, source: "フォルダ \(folder.lastPathComponent)")
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
