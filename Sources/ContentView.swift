//
//  ContentView.swift
//  QSProbe
//
//  画面構成:
//    ⓪ 埋め込み設定の実測値
//    ① 広告 (Advertiser) — Android から見えるか
//    ①-b 受信セッション — PIN 照合と受信進捗
//    ①-c フレーム履歴
//    ④ 送信 — 送るものを選ぶ
//    ② 探索 — 見つかったピアをタップすると送信開始
//    ③ 診断ログ (`Documents/Log/` にも書き出される)
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var advertiser = QuickShareAdvertiser()
    @StateObject private var browser = QuickShareBrowser()
    @StateObject private var logStore = DiagnosticLog.shared
    @StateObject private var session = InboundSession()
    @StateObject private var outbound = OutboundSession()

    @State private var showingLogShare = false
    @State private var didDump = false

    // --- 送信用の状態 ---
    @State private var pendingItems: [PendingItem] = []
    @State private var textToSend: String = ""
    // SwiftUI は同じビューに `.fileImporter` を 2 つ付けると片方しか効かない。
    // (M5 で「ファイルを選ぶ」が無反応になった原因がこれ)
    // モディファイアは 1 つだけにして、対象の種類を State で切り替える。
    @State private var showingImporter = false
    @State private var importerPicksFolder = false
    @State private var showingPhotoPicker = false
    /// Live Photo のペア動画も一緒に送るか。
    @State private var includeLivePhotoVideo = true
    /// フォルダ送信時、選んだフォルダ自身の名前を parent_folder に含めるか。
    @State private var includeRootFolderName = true

    var body: some View {
        NavigationStack {
            List {
                bundleSection
                advertiseSection
                inboundSection
                frameLogSection
                sendSection
                browseSection
                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("QSProbe M0")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingLogShare = true
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
            .sheet(isPresented: $showingLogShare) {
                ActivityView(items: [logStore.fullText])
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
            .sheet(isPresented: $showingPhotoPicker) {
                PhotoPicker(includeLivePhotoVideo: includeLivePhotoVideo) { urls in
                    showingPhotoPicker = false
                    guard !urls.isEmpty else { return }
                    let items = urls.map {
                        PendingItem(url: $0, parentFolder: "", isTemporary: true, scope: nil)
                    }
                    pendingItems.append(contentsOf: items)
                    qlog(.info, "送信候補に写真・動画 \(items.count) 件を追加しました")
                }
            }
        }
        .onAppear {
            // 着信した TCP 接続を InboundSession に渡す
            let target = session
            advertiser.onInboundConnection = { connection in
                Task { @MainActor in
                    target.handle(connection: connection)
                }
            }
            guard !didDump else { return }
            didDump = true
            qlog(.info, "==== QSProbe M5.1 起動 ====")
            Outbox.purge()
            BundleDiagnostics.dumpToLog()
        }
        .onChange(of: advertiser.currentInstanceName) { newValue in
            browser.selfInstanceName = newValue
        }
    }

    // MARK: - 埋め込み設定の実測値

    private var bundleSection: some View {
        Section {
            statusRow(
                title: "Bundle ID",
                value: BundleDiagnostics.bundleIdentifier,
                color: .secondary
            )
            statusRow(
                title: "LocalNetwork 用途文字列",
                value: BundleDiagnostics.localNetworkUsageDescription == nil ? "✗ 欠落" : "○ 有り",
                color: BundleDiagnostics.localNetworkUsageDescription == nil ? .red : .green
            )
            if let services = BundleDiagnostics.bonjourServices, !services.isEmpty {
                ForEach(services, id: \.self) { service in
                    statusRow(title: "NSBonjourServices", value: service, color: .green)
                }
            } else {
                statusRow(title: "NSBonjourServices", value: "✗ 欠落", color: .red)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("この App の設定を開く", systemImage: "gearshape")
            }
        } header: {
            Text("⓪ 埋め込み設定の実測値")
        } footer: {
            Text("ここが「欠落」ならビルド設定の問題です。すべて有りなのに権限が下りない場合は、設定 > プライバシーとセキュリティ > ローカルネットワーク に QSProbe が出ているか確認してください。")
        }
    }

    // MARK: - 広告

    private var advertiseSection: some View {
        Section {
            statusRow(
                title: "状態",
                value: advertiseStatusText,
                color: advertiseStatusColor
            )
            if case let .published(port, instanceName) = advertiser.state {
                statusRow(title: "TCP ポート", value: "\(port)", color: .secondary)
                statusRow(title: "インスタンス名", value: instanceName, color: .secondary)
            }
            statusRow(
                title: "TCP 着信回数",
                value: "\(advertiser.inboundConnectionCount)",
                color: advertiser.inboundConnectionCount > 0 ? .green : .secondary
            )

            Picker("サービスタイプ", selection: $advertiser.serviceTypeForm) {
                ForEach(QuickShareMdns.ServiceTypeForm.allCases) { form in
                    Text(form.rawValue).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .disabled(advertiser.state != .idle)

            Text(advertiser.serviceTypeForm.value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Picker("publish 方式", selection: $advertiser.backend) {
                ForEach(QuickShareAdvertiser.Backend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .disabled(advertiser.state != .idle)

            Toggle("TXT に IPv4 / f を含める", isOn: $advertiser.includeExtraTxtKeys)
                .disabled(advertiser.state != .idle)

            HStack {
                Button("広告を開始") { advertiser.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(advertiser.state != .idle)
                Spacer()
                Button("停止", role: .destructive) { advertiser.stop() }
                    .buttonStyle(.bordered)
                    .disabled(advertiser.state == .idle)
            }
        } header: {
            Text("① 広告 — Android から見えるか")
        } footer: {
            Text("開始したら Android 側で共有シートを開き、この端末が Quick Share の候補に出るか確認してください。候補をタップすると「TCP 着信回数」が増えます。")
        }
    }

    private var advertiseStatusText: String {
        switch advertiser.state {
        case .idle: return "停止中"
        case .starting: return "起動中…"
        case .listening: return "listener のみ (publish 未完了)"
        case .published: return "publish 済み"
        case .failed(let message): return "失敗: \(message)"
        }
    }

    private var advertiseStatusColor: Color {
        switch advertiser.state {
        case .published: return .green
        case .failed: return .red
        case .listening: return .orange
        default: return .secondary
        }
    }

    // MARK: - セッション

    private var inboundSection: some View {
        Section {
            statusRow(title: "状態", value: session.stage.rawValue, color: sessionStageColor)

            if let name = session.peerDeviceName {
                statusRow(title: "相手のデバイス名", value: name, color: .green)
            }

            if let pin = session.pinCode {
                HStack {
                    Text("確認 PIN").font(.headline)
                    Spacer()
                    Text(pin)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            if let error = session.lastError {
                statusRow(title: "エラー", value: error, color: .red)
            }

            // --- 受信するファイルと進捗 ---
            if !session.files.isEmpty {
                ForEach(session.files) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(file.displayPath)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if file.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        ProgressView(value: file.progress)
                        Text("\(byteText(file.receivedBytes)) / \(byteText(file.totalSize))  ·  \(file.mimeType)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .id("\(file.payloadId)-\(session.progressTick)")
                }
            }

            // --- 同意ボタン ---
            if session.hasPendingConsent {
                HStack {
                    Button {
                        session.accept()
                    } label: {
                        Label("受け入れる", systemImage: "checkmark")
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

            // --- 受信したテキスト ---
            ForEach(session.texts) { text in
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(text.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }

            Button(role: .destructive) {
                session.reset()
            } label: {
                Label("セッションをリセット", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("① -b セッション")
        } footer: {
            Text("Android から接続されると UKEY2 が走り、確認 PIN が出ます。Android の 4 桁と一致することを確認してから「受け入れる」を押してください。受信したファイルは Documents/Received/ に保存され、「ファイル」App から取り出せます。")
        }
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

    /// 送るものが選ばれていて、かつ送信中でないときだけタップできる。
    private var canSend: Bool {
        !outbound.isBusy && (!pendingItems.isEmpty || !textToSend.isEmpty)
    }

    private var pendingTotalBytes: Int64 {
        pendingItems.reduce(Int64(0)) { total, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            return total + size
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
            qlog(.info, "送信候補にファイル \(items.count) 件を追加しました")
        case .failure(let error):
            qlog(.warn, "ファイル選択に失敗: \(error)")
        }
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            // 大きなフォルダの列挙はメインスレッドを止めるのでバックグラウンドで
            let includeRoot = includeRootFolderName
            qlog(.info, "フォルダ \(folder.lastPathComponent) を走査しています…")
            DispatchQueue.global(qos: .userInitiated).async {
                let items = FolderScanner.scan(folder: folder, includeRootName: includeRoot)
                DispatchQueue.main.async {
                    pendingItems.append(contentsOf: items)
                    qlog(.ok, "フォルダ \(folder.lastPathComponent) から \(items.count) 件を追加しました")
                }
            }
        case .failure(let error):
            qlog(.warn, "フォルダ選択に失敗: \(error)")
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 受信済みフレーム

    private var frameLogSection: some View {
        Section {
            if session.summaries.isEmpty {
                Text("まだフレームを受信していません")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
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
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        Text(summary.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("① -c フレーム履歴")
        }
    }

    // MARK: - 送信

    private var sendSection: some View {
        Section {
            statusRow(title: "状態", value: outbound.stage.rawValue, color: outboundStageColor)

            if let target = outbound.targetName {
                statusRow(title: "送信先", value: target, color: .secondary)
            }

            if let pin = outbound.pinCode {
                HStack {
                    Text("確認 PIN").font(.headline)
                    Spacer()
                    Text(pin)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            if let error = outbound.lastError {
                statusRow(title: "エラー", value: error, color: .red)
            }

            // 送信するものを選ぶ
            Button {
                importerPicksFolder = false
                showingImporter = true
            } label: {
                Label("ファイルを選ぶ", systemImage: "doc.badge.plus")
            }
            .disabled(outbound.isBusy)

            Button {
                importerPicksFolder = true
                showingImporter = true
            } label: {
                Label("フォルダを選ぶ", systemImage: "folder.badge.plus")
            }
            .disabled(outbound.isBusy)

            Button {
                // Live Photo のペア動画を取り出すには写真ライブラリ権限が要る
                PhotoLibraryAccess.request { _ in
                    showingPhotoPicker = true
                }
            } label: {
                Label("写真・動画を選ぶ", systemImage: "photo.badge.plus")
            }
            .disabled(outbound.isBusy)

            Toggle("Live Photo のペア動画も送る", isOn: $includeLivePhotoVideo)
                .disabled(outbound.isBusy)

            Toggle("フォルダ名を parent_folder に含める", isOn: $includeRootFolderName)
                .disabled(outbound.isBusy)

            if !pendingItems.isEmpty {
                statusRow(
                    title: "送信候補",
                    value: "\(pendingItems.count) 件 / \(byteText(pendingTotalBytes))",
                    color: .blue
                )
                ForEach(pendingItems.prefix(20)) { item in
                    Text(item.displayPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if pendingItems.count > 20 {
                    Text("… ほか \(pendingItems.count - 20) 件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(role: .destructive) {
                    clearPendingItems()
                } label: {
                    Label("選択を解除", systemImage: "xmark.circle")
                }
                .disabled(outbound.isBusy)
            }

            TextField("テキストを送る (任意)", text: $textToSend, axis: .vertical)
                .lineLimit(1...4)
                .disabled(outbound.isBusy)

            // 送信中の進捗
            ForEach(outbound.files) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(file.displayPath)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if file.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    ProgressView(value: file.progress)
                    Text("\(byteText(file.sentBytes)) / \(byteText(file.totalSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .id("out-\(file.payloadId)-\(outbound.progressTick)")
            }

            if outbound.isBusy {
                Button(role: .destructive) {
                    outbound.cancel()
                } label: {
                    Label("送信を中止", systemImage: "stop.circle")
                }
            } else if outbound.stage != .idle {
                Button {
                    outbound.reset()
                } label: {
                    Label("送信状態をリセット", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("④ 送信 — iPad から Android へ")
        } footer: {
            Text("送るものを選んでから、下の「② 探索」で相手をタップしてください。Android 側で Quick Share の受信画面を開いた状態にしておく必要があります。")
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

    // MARK: - 探索

    private var browseSection: some View {
        Section {
            statusRow(
                title: "状態",
                value: browseStatusText,
                color: browseStatusColor
            )

            Picker("サービスタイプ", selection: $browser.serviceTypeForm) {
                ForEach(QuickShareMdns.ServiceTypeForm.allCases) { form in
                    Text(form.rawValue).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .disabled(browser.state != .idle)

            Toggle("自分自身を一覧から除外", isOn: $browser.excludeSelf)

            HStack {
                Button("探索を開始") { browser.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.state != .idle)
                Spacer()
                Button("停止", role: .destructive) { browser.stop() }
                    .buttonStyle(.bordered)
                    .disabled(browser.state == .idle)
            }

            if browser.peers.isEmpty {
                Text("ピアはまだ見つかっていません")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(browser.peers) { peer in
                    Button {
                        outbound.send(
                            items: pendingItems,
                            text: textToSend.isEmpty ? nil : textToSend,
                            to: peer.endpoint,
                            peerName: peer.displayName
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName)
                                    .font(.body.weight(.medium))
                                Text("type=\(String(describing: peer.deviceType)) / \(peer.id)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(peer.endpointDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(canSend ? .blue : .secondary)
                        }
                    }
                    .disabled(!canSend)
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("② 探索 — Android を見つけられるか")
        } footer: {
            Text("Android 側で Quick Share の受信画面を開いた状態にすると、ここに現れます。")
        }
    }

    private var browseStatusText: String {
        switch browser.state {
        case .idle: return "停止中"
        case .browsing: return "探索中"
        case .failed(let message): return "失敗: \(message)"
        }
    }

    private var browseStatusColor: Color {
        switch browser.state {
        case .browsing: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    // MARK: - ログ

    private var logSection: some View {
        Section {
            if logStore.entries.isEmpty {
                Text("ログはまだありません").foregroundStyle(.secondary).font(.footnote)
            } else {
                ForEach(logStore.entries.reversed()) { entry in
                    Text(entry.formatted)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: entry.level))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("③ 診断ログ")
        } footer: {
            Text("同じ内容が Documents/Log/ にも書き出されます。「ファイル」App の QSProbe フォルダから取り出せます。")
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

    // MARK: - 共通

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
}

// MARK: - 共有シート

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
