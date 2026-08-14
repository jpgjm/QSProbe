//
//  AccountLinkView.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  ## 作り直した理由
//
//  開発の段階 (第1段〜第5段) をそのまま画面の見出しにしていた。
//  作る側の都合であって、使う側には意味がない。しかも `DisclosureGroup` が
//  4 階層に入れ子になっていて、**開くまで中身が分からない**状態だった。
//
//  段階ではなく**目的**で分け直し、別画面に移した。
//
//  ```
//  連携        サインインしているか
//  受信の設定  自動受信を誰に許すか
//  この端末    自分の証明書と登録
//  接続先      Google 側の値
//  ```
//
//  調査に使っていた道具 (経路の総当たり、運び方の切り替え、tokeninfo など) は
//  役目を終えたので画面から外した。手順と結論は `docs/account-linking.md` に
//  残してあるので、必要になれば書き直せる。
//

import SwiftUI
import UIKit

// MARK: - メイン画面に置く 1 行

/// 状態を 1 行で示して、詳しくは別画面へ送る。
///
/// これまでは開いて何度かタップしないと、連携しているのか証明書が
/// あるのかも分からなかった。
struct AccountSummaryRow: View {

    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var certificates = CertificateStore.shared
    @ObservedObject private var localCertificate = LocalCertificateStore.shared

    var body: some View {
        Section {
            NavigationLink {
                AccountLinkView()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label("アカウント連携", systemImage: "person.badge.key")
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(summaryColor)
                }
            }
        } header: {
            Text("実験機能")
        } footer: {
            Text("Google の非公開 API を使う実験です。"
                 + "オフのあいだは通信も保存も一切しません。")
        }
    }

    private var summary: String {
        guard store.isEnabled else { return "オフ" }
        guard store.tokens != nil else { return "未サインイン" }

        var parts = ["連携済み"]
        parts.append("証明書 \(certificates.certificates.count) 件")
        if let active = localCertificate.active {
            parts.append("登録の期限 \(LocalCertificateStore.remainingText(active))")
        } else if localCertificate.certificates.isEmpty {
            parts.append("この端末は未登録")
        } else {
            parts.append("証明書の期限切れ")
        }
        return parts.joined(separator: " / ")
    }

    private var summaryColor: Color {
        guard store.isEnabled, store.tokens != nil else { return .secondary }
        if localCertificate.certificates.isEmpty { return .orange }
        guard let active = localCertificate.active else { return .red }
        return active.expiresSoon ? .orange : .green
    }
}

// MARK: - 別画面

struct AccountLinkView: View {

    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var certificates = CertificateStore.shared
    @ObservedObject private var localCertificate = LocalCertificateStore.shared

    @State private var showingWarning = false
    @State private var showingPublishWarning = false

    @State private var editClientId = ""
    @State private var editClientSecret = ""
    @State private var editScopes = ""
    @State private var didLoadOverrides = false

    var body: some View {
        List {
            enableSection
            if store.isEnabled {
                linkSection
                receiveSection
                deviceSection
                endpointSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("アカウント連携")
        .navigationBarTitleDisplayMode(.inline)
        .alert("実験機能を有効にしますか", isPresented: $showingWarning) {
            Button("やめる", role: .cancel) { }
            Button("承認して有効にする", role: .destructive) { store.enable() }
        } message: {
            Text(warningMessage)
        }
        .alert("アカウントに端末を登録しますか", isPresented: $showingPublishWarning) {
            Button("やめる", role: .cancel) { }
            Button("登録する", role: .destructive) { store.publishDevice() }
        } message: {
            Text(publishWarningMessage)
        }
        .onAppear(perform: loadOverridesOnce)
    }

    // MARK: - 有効化

    private var enableSection: some View {
        Section {
            Toggle("この実験機能を使う", isOn: enabledBinding)
        } footer: {
            Text("オフにすると、保存しているトークンと証明書も消えます。")
        }
    }

    // MARK: - 連携

    @ViewBuilder
    private var linkSection: some View {
        Section {
            if !AccountConfig.isConfigured {
                notice("client_id が未設定です。下の「接続先」に入れてください。",
                       color: .orange)
            }

            row("状態", store.status.label, color: statusColor)

            if let tokens = store.tokens {
                row("有効期限", tokens.expiryText,
                    color: tokens.isExpired ? .orange : .green)
                if let scope = tokens.scope {
                    detail("降りたスコープ", scope)
                }
            }

            if let error = store.lastErrorDetail {
                failure(error)
            }

            Button {
                store.signIn()
            } label: {
                Label(store.tokens == nil ? "Google でサインイン" : "認可をやり直す",
                      systemImage: "key.fill")
            }
            .disabled(store.status == .authorizing || !AccountConfig.isConfigured)

            if store.tokens != nil {
                Button {
                    store.refreshNow()
                } label: {
                    Label("トークンを更新する", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    store.signOut(revokeOnServer: false)
                } label: {
                    Label("サインアウト", systemImage: "rectangle.portrait.and.arrow.right")
                }

                Button(role: .destructive) {
                    store.signOut(revokeOnServer: true)
                } label: {
                    Label("Google 側の連携も解除する", systemImage: "xmark.shield")
                }
            }
        } header: {
            Text("連携")
        }
    }

    // MARK: - 受信の設定

    private var receiveSection: some View {
        Section {
            Toggle("本人確認できた相手だけ自動で受け取る",
                   isOn: $store.autoAcceptVerifiedOnly)

            row("持っている証明書", "\(certificates.certificates.count) 件",
                color: certificates.certificates.isEmpty ? .orange : .green)

            Button {
                store.fetchSharedCredentials()
            } label: {
                Label(store.isFetchingCredentials ? "取得中…" : "証明書を取り直す",
                      systemImage: "arrow.down.circle")
            }
            .disabled(store.tokens == nil || store.isFetchingCredentials)
        } header: {
            Text("受信の設定")
        } footer: {
            Text("「確認せずに受け取る」がオンのときに効きます。"
                 + "署名を検証できた相手からは確認なしで受け取り、"
                 + "検証できない相手には、これまでどおり確認コードを出します。"
                 + "証明書が 0 件だと誰も検証できないので、自動受信は行われません。")
        }
    }

    // MARK: - この端末

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if localCertificate.certificates.isEmpty {
                Text("証明書がありません。作って登録すると、"
                     + "相手の「お使いのデバイス」に載ります。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                row("device_id", localCertificate.deviceId, color: .secondary)
                expiryRow
                selfCheckRows
            }

            Button {
                localCertificate.generate(deviceName: advertisedDeviceName)
            } label: {
                Label(localCertificate.certificates.isEmpty ? "証明書を作る" : "作り直す",
                      systemImage: "plus.rectangle.on.folder")
            }

            if !localCertificate.certificates.isEmpty {
                Button(role: .destructive) {
                    showingPublishWarning = true
                } label: {
                    Label("この端末を登録する", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(store.tokens == nil)

                Toggle("広告で端末名を隠す", isOn: $localCertificate.hideNameInAdvertisement)

                Button(role: .destructive) {
                    localCertificate.clear()
                } label: {
                    Label("証明書を消す", systemImage: "trash")
                }
            }
        } header: {
            Text("この端末")
        } footer: {
            Text("証明書には、いまの端末名「\(advertisedDeviceName)」が入ります。"
                 + "名前を変えたら作り直してください。"
                 + "登録は Google アカウントへの書き込みです。"
                 + "取り消すにはアカウントの設定から端末を削除します。"
                 + "作り直したら登録もやり直してください。"
                 + "名前を隠すと、証明書を持つ相手にだけ名前が見えます。")
        }
    }

    @ViewBuilder
    private var expiryRow: some View {
        if let active = localCertificate.active {
            row("有効期限", LocalCertificateStore.remainingText(active),
                color: active.expiresSoon ? .orange : .green)
            if active.expiresSoon {
                notice("期限が近づいています。作り直して登録し直してください。",
                       color: .orange)
            }
        } else {
            notice("有効な証明書がありません。作り直して登録し直してください。",
                   color: .red)
        }
    }

    @ViewBuilder
    private var selfCheckRows: some View {
        if !localCertificate.selfCheck.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("自己検証").font(.caption)
                ForEach(Array(localCertificate.selfCheck.enumerated()), id: \.offset) {
                    _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(checkFailed(line) ? .red : .green)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 接続先

    private var endpointSection: some View {
        Section {
            PasteableField(
                title: "client_id",
                placeholder: "…apps.googleusercontent.com",
                text: $editClientId
            )
            PasteableField(
                title: "client_secret",
                placeholder: "GOCSPX-…",
                text: $editClientSecret,
                isSecret: true
            )
            PasteableField(
                title: "scope",
                placeholder: AccountConfig.defaultScopes.joined(separator: " "),
                text: $editScopes
            )

            Button {
                saveOverrides()
            } label: {
                Label("保存する", systemImage: "tray.and.arrow.down")
            }

            Button(role: .destructive) {
                store.resetConfiguration()
                loadOverrides()
            } label: {
                Label("既定値に戻す", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("接続先")
        } footer: {
            Text("client_id と client_secret は nearby_share.exe から取り出した値です。"
                 + "リポジトリには入れていないので、ここに入力してください。"
                 + "scope は空欄なら既定値を使います。")
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

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(.caption2)
                .foregroundStyle(color)
        }
        .padding(.vertical, 2)
    }

    private func failure(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("直近の失敗")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if let hint = AccountHint.forError(text) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }


    private var statusColor: Color {
        switch store.status {
        case .signedIn:    return .green
        case .authorizing: return .orange
        case .failed:      return .red
        default:           return .secondary
        }
    }

    private func checkFailed(_ line: String) -> Bool {
        line.contains("失敗") || line.contains("不一致") || line.contains("開けません")
    }

    private var advertisedDeviceName: String {
        DeviceNameStore.shared.effectiveName
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { isOn in
                if isOn {
                    showingWarning = true
                } else {
                    store.disable()
                }
            }
        )
    }

    // MARK: - 接続先の読み書き

    private func loadOverridesOnce() {
        guard !didLoadOverrides else { return }
        didLoadOverrides = true
        loadOverrides()
    }

    private func loadOverrides() {
        editClientId = AccountConfig.rawOverride(AccountConfig.Key.clientId)
        editClientSecret = AccountConfig.rawOverride(AccountConfig.Key.clientSecret)
        editScopes = AccountConfig.rawOverride(AccountConfig.Key.scopes)
    }

    private func saveOverrides() {
        AccountConfig.setOverride(AccountConfig.Key.clientId, editClientId)
        AccountConfig.setOverride(AccountConfig.Key.clientSecret, editClientSecret)
        AccountConfig.setOverride(AccountConfig.Key.scopes, editScopes)
        qlog(.info, "Account: 接続先を保存しました")
    }

    private var warningMessage: String {
        """
        この機能は Google の非公開 API を使用しています。
        Google 公認ではなく、いつ動かなくなっても、その時点で使えません。
        利用規約に反する可能性があり、Google アカウント側で警告が出ることがあります。
        承認したうえで有効にしてください。
        """
    }

    private var publishWarningMessage: String {
        """
        Google アカウントのデバイス一覧に、この端末が追加されます。
        読み取りだけだったこれまでと違い、アカウント側が変わります。

        device_id: \(localCertificate.deviceId)

        取り消すには Google アカウントの設定から端末を削除してください。
        """
    }
}

// MARK: - 失敗への手当て

/// 失敗の文字列から、次に何をすればよいかを引く。
///
/// エラーをそのまま出しても、次の一手が分からなければ意味がない。
enum AccountHint {

    static func forError(_ text: String) -> String? {
        if text.contains("invalid_client") {
            return "client_secret が違うか未設定です。接続先を確認してください。"
        }
        if text.contains("redirect_uri_mismatch") {
            return "この client_id ではループバック以外を受け付けません。"
        }
        if text.contains("invalid_scope") || text.contains("restricted_client") {
            return "scope をこの client_id に紐づいたものだけにしてください。"
        }
        if text.contains("UNAUTHENTICATED") || text.contains("401") {
            return "トークンが切れています。更新するか、サインインし直してください。"
        }
        if text.contains("PERMISSION_DENIED") || text.contains("403") {
            return "このアカウントでは許可されていません。"
        }
        if text.contains("UNIMPLEMENTED") {
            return "宛先が違います。Google 側の仕様が変わった可能性があります。"
        }
        if text.contains("notSignedIn") || text.contains("サインインしていません") {
            return "先にサインインしてください。"
        }
        return nil
    }
}
