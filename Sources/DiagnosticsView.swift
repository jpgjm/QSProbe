//
//  DiagnosticsView.swift
//  QSProbe
//
//  診断をまとめた画面。
//
//  ## なぜ別画面にしたか
//
//  受信したフレーム・埋め込み設定・ログは、どれも「普段は見ないが、
//  困ったときに必要なもの」。メインの一覧に畳んで置いていたが、
//  DisclosureGroup が並ぶと**開くまで中身が分からない**うえ、
//  受信や送信の操作の間に挟まって邪魔になっていた。
//
//  共有と消去も、これまでは右上のメニューの中にあって見つけにくかった。
//  ログのすぐ下に置く。
//

import SwiftUI

struct DiagnosticsView: View {

    @ObservedObject var session: InboundSession
    @ObservedObject private var logStore = DiagnosticLog.shared

    /// ログの共有。呼び出し側 (ContentView) が持つ処理を借りる。
    let onShare: () -> Void

    /// BGTask 識別子の検証モード。次回起動から効く。
    @AppStorage(BGTaskIdentifierProbe.defaultsKey) private var pendingModeRaw
        = BGTaskIdentifierMode.auto.rawValue

    var body: some View {
        List {
            framesSection
            bundleSection
            bgTaskSection
            logSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("診断")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 受信したフレーム

    private var framesSection: some View {
        Section {
            if session.summaries.isEmpty {
                Text("まだありません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.summaries) { summary in
                    frameRow(summary)
                }

                Button(role: .destructive) {
                    session.reset()
                } label: {
                    Label("受信の表示を消す", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("受信したフレーム (\(session.summaries.count))")
        }
    }

    private func frameRow(_ summary: InboundFrameSummary) -> some View {
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

    // MARK: - 埋め込み設定

    private var bundleSection: some View {
        Section {
            row("Bundle ID", BundleDiagnostics.bundleIdentifier, color: .secondary)
            row(
                "ローカルネットワーク",
                BundleDiagnostics.localNetworkUsageDescription == nil ? "✗ 欠落" : "○ 有り",
                color: BundleDiagnostics.localNetworkUsageDescription == nil ? .red : .green
            )
            if let services = BundleDiagnostics.bonjourServices, !services.isEmpty {
                ForEach(services, id: \.self) { service in
                    row("Bonjour", service, color: .green)
                }
            } else {
                row("Bonjour", "✗ 欠落", color: .red)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("この App の設定を開く", systemImage: "gearshape")
            }
        } header: {
            Text("埋め込み設定")
        } footer: {
            Text("Info.plist に入っている値です。欠けていると、"
                 + "ローカルネットワークの許可や検出が働きません。")
        }
    }

    // MARK: - BGTask 識別子の検証

    /// SideStore の bundle ID 書き換えと BGTask 許可識別子の関係を、
    /// 同じビルドの中で A/B するための区画。既定は「通常」で、
    /// 転送の動作には影響しない。
    ///
    /// 詳細と各モードの期待値は BGTaskIdentifierProbe.swift を参照。
    private var bgTaskSection: some View {
        Section {
            row("実行時 Bundle ID", BundleDiagnostics.bundleIdentifier, color: .secondary)

            if let permitted = BundleDiagnostics.permittedBGTaskIdentifiers, !permitted.isEmpty {
                ForEach(permitted, id: \.self) { identifier in
                    let under = BundleDiagnostics.isUnderRuntimeBundleID(identifier)
                    row(
                        under ? "許可識別子 (配下)" : "許可識別子 (配下でない)",
                        identifier,
                        color: under ? .green : .orange
                    )
                }
            } else {
                row("許可識別子", "✗ 欠落または空", color: .red)
            }

            Picker("次回起動から使う識別子", selection: $pendingModeRaw) {
                ForEach(BGTaskIdentifierMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }

            let pending = BGTaskIdentifierMode(rawValue: pendingModeRaw) ?? .auto
            Text(pending.expectation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if pending != BGTaskIdentifierProbe.activeMode {
                Label("アプリを再起動すると切り替わります", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            row("この起動のモード", BGTaskIdentifierProbe.activeMode.label, color: .secondary)

            ForEach(BGTaskIdentifierProbe.registerOutcomes) { outcome in
                row(
                    outcome.accepted ? "register() 成功" : "register() 失敗",
                    outcome.identifier,
                    color: outcome.accepted ? .green : .red
                )
            }

            Button {
                BackgroundTransferTask.shared.runIdentifierProbe()
            } label: {
                Label("転送なしで申請だけ試す", systemImage: "play.circle")
            }

            if let submit = BGTaskIdentifierProbe.lastSubmit {
                row("直近の申請", submit, color: .secondary)
            }

            if let fired = BGTaskIdentifierProbe.lastLaunchFired {
                if fired {
                    let latency = BGTaskIdentifierProbe.lastLaunchLatencyMs
                        .map { "起動しました (\($0) ms)" } ?? "起動しました"
                    row("ハンドラ", latency, color: .green)
                } else {
                    row("ハンドラ", "★ 起動しませんでした", color: .red)
                }
            }
        } header: {
            Text("BGTask 識別子の検証")
        } footer: {
            Text("Info.plist は変えないので、モードを切り替えても再インストールや"
                 + "端末の再起動は要りません。アプリを終了して開き直すだけです。"
                 + "検証が終わったら「通常」に戻してください。")
        }
    }

    // MARK: - ログ

    private var logSection: some View {
        Section {
            if logStore.entries.isEmpty {
                Text("まだありません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // 新しいものから。全件を一度に描くと重いので頭を切る。
                // **記録は切っていない。** 1 行ごとにファイルへ追記しているので、
                // 共有した zip には起動からの全件が入る。
                ForEach(logStore.entries.reversed().prefix(500)) { entry in
                    Text(entry.formatted)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: entry.level))
                        .textSelection(.enabled)
                }
            }

            Button {
                onShare()
            } label: {
                Label("ログを共有", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                logStore.clear()
            } label: {
                Label("ログを消去", systemImage: "trash")
            }
        } header: {
            Text("ログ (\(logStore.entries.count))")
        } footer: {
            Text("画面に出しているのは直近 500 件です。"
                 + "記録そのものは制限していないので、共有すると起動からの全件が"
                 + "テキストと JSON Lines の zip で出ます。")
        }
    }

    // MARK: - 部品

    private func row(_ title: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}
