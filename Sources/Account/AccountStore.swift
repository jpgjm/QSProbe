//
//  AccountStore.swift
//  QSProbe — 実験機能 / アカウント連携 (第1段)
//
//  画面から見える状態をひとまとめにした層。
//
//  ## 既定はオフ
//
//  この機能は Google の非公開 API を叩くため、**明示的に承認するまで
//  一切動かない**ようにしてあります。トグルを入れるときに警告を出し、
//  承認された事実も別に記録します。
//
//  ## 既存コードから独立している
//
//  ここから既存の送受信の経路を触ることはありません。第4段
//  (InboundSession への組み込み) まで、この層は「トークンを取ってきて
//  持っているだけ」です。
//

import Foundation
import Combine
import SwiftProtobuf

enum AccountStoreError: Error, LocalizedError {
    case notSignedIn
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "サインインしていません"
        }
    }
}

@MainActor
final class AccountStore: ObservableObject {

    static let shared = AccountStore()

    enum Status: Equatable {
        case disabled
        case signedOut
        case authorizing
        case signedIn
        case failed(String)

        var label: String {
            switch self {
            case .disabled:    return "無効"
            case .signedOut:   return "未サインイン"
            case .authorizing: return "認可中…"
            case .signedIn:    return "サインイン済み"
            case .failed:      return "失敗"
            }
        }
    }

    // MARK: - 公開する状態

    @Published private(set) var status: Status = .disabled
    @Published private(set) var tokens: AccountTokens?

    /// 直近の失敗の内訳 (画面に出す。トークンは含めない)。
    @Published private(set) var lastErrorDetail: String?
    @Published private(set) var lastHTTPStatus: Int?
    @Published private(set) var lastRedirectURI: String?

    /// `GetAccountInfo` が返した識別子。第 3 段の資源名に使う。
    @Published private(set) var currentDusi: String?

    /// `QuerySharedCredentials` の結果 (画面表示用)。
    @Published private(set) var credentialSummary: [String] = []

    /// 証明書を取得中か。連打で同じ要求が並ぶのを防ぐ。
    @Published private(set) var isFetchingCredentials = false

    /// 通信方式。`application/grpc` と `$rpc` のどちらも通ることが確認できている。
    /// 既定は `.grpc`。片方が塞がれたときのために `withEachWireFormat` で順に試す。
    let wireFormat: NearbyWireFormat = .grpc

    /// 実験機能そのものの有効/無効。
    @Published private(set) var isEnabled: Bool

    /// 既に警告に同意したか。一度同意すれば毎回は出さない。
    @Published private(set) var didAcceptWarning: Bool

    /// プライベートセッションで認可するか。既定はオフ (Safari のログインを使い回す)。
    @Published var prefersEphemeralSession: Bool {
        didSet { defaults.set(prefersEphemeralSession, forKey: Keys.ephemeral) }
    }

    /// リダイレクトの受け口。
    ///
    /// カスタムスキームはこの client_id では使えないと実測で確定したので、
    /// 選ばせずループバックに固定する。
    let redirectMode: AccountRedirectMode = .loopback

    /// 自動承認を「本人確認できた相手だけ」に絞るか。
    ///
    /// 署名の検証は接続ごとに新しい authString を対象にするので、
    /// 広告を丸ごとコピーして名乗る手 (リプレイ) では通らない。
    /// **自動承認の相手を絞る根拠として使えるのは、この検証だけ。**
    @Published var autoAcceptVerifiedOnly: Bool {
        didSet {
            defaults.set(autoAcceptVerifiedOnly, forKey: Keys.verifiedOnly)
            // 受信の挙動が変わる設定なので記録に残す。
            // 「なぜ自動で受かったのか」を後から追えるようにするため。
            qlog(.info, "Account: 自動受信の絞り込みを "
                + (autoAcceptVerifiedOnly ? "有効" : "無効") + " にしました")
        }
    }

    // MARK: - 内部

    private enum Keys {
        static let enabled = "QSProbe.account.enabled"
        static let accepted = "QSProbe.account.acceptedWarning"
        static let ephemeral = "QSProbe.account.ephemeralSession"
        static let verifiedOnly = "QSProbe.account.autoAcceptVerifiedOnly"
    }

    private let defaults = UserDefaults.standard
    private let oauth = AccountOAuth()

    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        didAcceptWarning = defaults.bool(forKey: Keys.accepted)
        prefersEphemeralSession = defaults.bool(forKey: Keys.ephemeral)
        // 既定はオン。実験機能を使う人にとって、絞られていないほうが驚く。
        autoAcceptVerifiedOnly = defaults.object(forKey: Keys.verifiedOnly) as? Bool ?? true

        if isEnabled {
            tokens = AccountKeychain.load()
            status = tokens == nil ? .signedOut : .signedIn
            if let tokens {
                qlog(.info, "Account: 保存されたトークンを読み込みました (期限 \(tokens.expiryText))")
            }
        }
    }

    // MARK: - 有効化 / 無効化

    /// 警告に同意したうえで有効にする。
    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        didAcceptWarning = true
        defaults.set(true, forKey: Keys.enabled)
        defaults.set(true, forKey: Keys.accepted)

        tokens = AccountKeychain.load()
        status = tokens == nil ? .signedOut : .signedIn
        qlog(.warn, "Account: ⚠ 実験機能 (アカウント連携) を有効にしました")
    }

    /// 無効にする。保存済みのトークンもこの時点で消す。
    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)

        AccountKeychain.delete()
        tokens = nil
        status = .disabled
        lastErrorDetail = nil
        lastHTTPStatus = nil
        qlog(.info, "Account: 実験機能を無効にし、保存していたトークンを消しました")
    }

    // MARK: - サインイン

    func signIn() {
        guard isEnabled else { return }
        guard status != .authorizing else {
            qlog(.warn, "Account: すでに認可中です")
            return
        }

        status = .authorizing
        lastErrorDetail = nil
        lastHTTPStatus = nil

        Task {
            do {
                let result = try await oauth.authorize(
                    mode: redirectMode,
                    ephemeral: prefersEphemeralSession
                )
                tokens = result
                AccountKeychain.save(result)
                status = .signedIn
                lastHTTPStatus = oauth.lastHTTPStatus
                lastRedirectURI = oauth.lastRedirectURI
                qlog(.ok, "Account: ★ 第1段クリア — 同意画面を通り、トークンを取得できました")
            } catch {
                finish(with: error)
            }
        }
    }

    func signOut(revokeOnServer: Bool) {
        guard let current = tokens else {
            status = isEnabled ? .signedOut : .disabled
            return
        }
        Task {
            if revokeOnServer {
                await oauth.revoke(current)
            }
            AccountKeychain.delete()
            tokens = nil
            status = isEnabled ? .signedOut : .disabled
            lastErrorDetail = nil
            qlog(.info, "Account: サインアウトしました")
        }
    }

    // MARK: - 更新

    func refreshNow() {
        guard let current = tokens else { return }
        Task {
            do {
                let updated = try await oauth.refresh(current)
                tokens = updated
                AccountKeychain.save(updated)
                status = .signedIn
                lastHTTPStatus = oauth.lastHTTPStatus
                lastErrorDetail = nil
            } catch {
                finish(with: error)
            }
        }
    }

    // MARK: - 疎通確認 (第 2 段)

    /// 副作用のない `GetAccountInfo` を叩いて、Google がこのトークンを受理するかを見る。
    ///
    /// - 成功 → `current_dusi` を返す。以降の呼び出しで使う識別子。
    /// - 失敗 → 例外を投げる。`grpc-status` の中身は `Account gRPC:` のログを参照。
    ///
    /// **書き込みは一切しない。** アカウントに端末は登録されない。
    /// 端末登録が起きるのは第 3 段 `PublishDevice` から。
    func pingGetAccountInfo() {
        Task {
            let format = wireFormat
            do {
                let dusi = try await runGetAccountInfo(wireFormat: format)
                currentDusi = dusi
                lastErrorDetail = nil
                qlog(.ok, "Account: ★★ GetAccountInfo 成功 (方式=\(format.label)) — "
                    + "current_dusi = \(dusi)")
            } catch {
                lastErrorDetail = String(describing: error)
                qlog(.error, "Account: ✗ GetAccountInfo 失敗 (方式=\(format.label)) — \(error)")
            }
        }
    }


    private func runGetAccountInfo(wireFormat: NearbyWireFormat) async throws -> String {
        let token = try await validAccessToken()
        let client = NearbyServiceClient()
        client.wireFormat = wireFormat
        let info = try await client.getAccountInfo(accessToken: token)
        return info.currentDusi.isEmpty ? "(空)" : info.currentDusi
    }

    /// 期限が近ければ更新したうえで、使えるアクセストークンを返す。
    private func validAccessToken() async throws -> String {
        guard var current = tokens else {
            throw AccountStoreError.notSignedIn
        }
        // 期限切れなら更新してから叩く。60 秒の余裕で判定している。
        if current.isExpired, current.refreshToken != nil {
            qlog(.info, "Account: トークン期限切れが近いので更新します")
            let updated = try await oauth.refresh(current)
            tokens = updated
            AccountKeychain.save(updated)
            current = updated
        }
        return current.accessToken
    }

    // MARK: - 第 3 段 (読み取りのみ)


    /// 相手の公開証明書を取る。**書き込みは無い。**
    ///
    /// `name` が `devices/{device_id}` の形で、`device_id` の出どころが未確定。
    /// 欄が空なら `devices/{current_dusi}` を試す。
    func fetchSharedCredentials() {
        guard !isFetchingCredentials else {
            qlog(.info, "Account: 証明書の取得はすでに走っています")
            return
        }
        isFetchingCredentials = true
        Task {
            defer { isFetchingCredentials = false }
            do {
                let token = try await validAccessToken()
                let name = resolvedDeviceResourceName()
                qlog(.info, "Account: QuerySharedCredentials name = \(name)")

                let response = try await withEachWireFormat("QuerySharedCredentials") { client in
                    try await client.querySharedCredentials(name: name, accessToken: token)
                }

                lastErrorDetail = nil
                let items = response.sharedCredentials
                qlog(.ok, "Account: ★★ QuerySharedCredentials 成功 — \(items.count) 件")

                if !response.nextPageToken.isEmpty {
                    qlog(.info, "Account:   next_page_token あり (続きがあります)")
                }

                // 中身を PublicCertificate として解釈できるかが第 4 段の前提。
                let decoded = CertificateStore.shared.ingest(items)
                credentialSummary = CertificateStore.shared.certificates.prefix(12).map {
                    $0.summary
                }

                for stored in CertificateStore.shared.certificates.prefix(5) {
                    qlog(.info, "Account:   \(stored.summary)")
                }
                if CertificateStore.shared.certificates.count > 5 {
                    qlog(.info, "Account:   (以降は省略。全 \(decoded) 件を保持しています)")
                }

                if items.isEmpty {
                    qlog(.warn, "Account: 0 件でした。資源名が違うか、"
                        + "まだ端末を登録していない (PublishDevice 未実施) かのどちらかです")
                }
            } catch {
                lastErrorDetail = String(describing: error)
                credentialSummary = []
                qlog(.error, "Account: ✗ QuerySharedCredentials 失敗 — \(error)")
            }
        }
    }

    /// 通る運び方を順に試し、最初に成功したものを返す。
    ///
    /// `grpc` は成功時の `grpc-status` が見えず、`$rpc` は失敗が HTTP
    /// ステータスで返る。どちらが素直かは呼ぶ RPC によって違うので、
    /// 選ばせるより両方試したほうが 1 回のタップで分かることが多い。
    private func withEachWireFormat<T>(
        _ label: String,
        _ body: (NearbyServiceClient) async throws -> T
    ) async throws -> T {
        // いま選ばれている方式を先に試し、残りを続ける。
        var order = [wireFormat]
        order.append(contentsOf: NearbyWireFormat.usable.filter { $0 != wireFormat })

        var lastError: Error?
        for format in order {
            let client = NearbyServiceClient()
            client.wireFormat = format
            do {
                let result = try await body(client)
                if format != wireFormat {
                    qlog(.ok, "Account: \(label) は \(format.label) で通りました")
                }
                return result
            } catch {
                qlog(.warn, "Account: \(label) — \(format.label) では失敗 (\(error))")
                lastError = error
            }
        }
        throw lastError ?? AccountStoreError.notSignedIn
    }

    /// `QuerySharedCredentials` に渡す資源名。
    ///
    /// `devices/{device_id}` の形。`device_id` は端末側で決める 10 文字だが、
    /// サーバは未知の値でもアカウント全体の証明書を返す。実測では
    /// `GetAccountInfo` が返す `current_dusi` で通っている。
    private func resolvedDeviceResourceName() -> String {
        guard let dusi = currentDusi, !dusi.isEmpty, dusi != "(空)" else {
            return "devices/\(LocalCertificateStore.shared.deviceId)"
        }
        return "devices/\(dusi)"
    }

    private static func hexPreview(_ data: Data) -> String {
        let head = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        return data.count > 16 ? head + "…" : head
    }

    // MARK: - 第 5 段 (書き込み)

    /// 端末と証明書をアカウントに登録する。
    ///
    /// **これは書き込み。** Google アカウントのデバイス一覧にこの端末が載る。
    /// 呼ぶ前に必ず確認を取ること。
    ///
    /// 上流の作りに合わせて、可視性ごとに証明書をまとめて送る。
    /// 応答に「連絡先が削除された」が入っていたら、証明書を作り直して
    /// もう一度呼ぶべきだが、まずは 1 回で通るかを見る。
    func publishDevice() {
        let local = LocalCertificateStore.shared
        guard !local.certificates.isEmpty else {
            lastErrorDetail = "先に証明書を作ってください"
            return
        }

        Task {
            do {
                let token = try await validAccessToken()
                let request = Self.buildPublishRequest(
                    deviceId: local.deviceId,
                    displayName: local.certificates.first?.deviceName ?? "iPad",
                    certificates: local.certificates
                )

                qlog(.warn, "Account: ⚠ PublishDevice を呼びます (書き込み)")
                qlog(.info, "Account:   devices/\(local.deviceId)")
                qlog(.info, "Account:   証明書 \(local.certificates.count) 枚")

                let client = NearbyServiceClient()
                client.wireFormat = wireFormat
                let response = try await client.publishDevice(request, accessToken: token)

                lastErrorDetail = nil
                qlog(.ok, "Account: ★★★ PublishDevice に成功しました")
                // 登録したら名乗る義務が生まれる。広告を証明書ベースに切り替える。
                LocalCertificateStore.shared.markPublished()
                qlog(.info, "Account:   contact_updates = \(response.contactUpdates)")

                // 登録すると、相手はこちらを「自分のデバイス」として扱い始める。
                // そのとき相手も証明書を切り替えることがあるので、こちらの手元を
                // 更新しておかないと、相手を特定できずに接続を切ることになる。
                qlog(.info, "Account: 登録に合わせて証明書を取り直します")
                fetchSharedCredentials()
                if response.contactRemoved {
                    qlog(.warn, "Account:   連絡先が削除されています。"
                        + "本来は証明書を作り直してもう一度呼ぶ場面です")
                }
            } catch {
                lastErrorDetail = String(describing: error)
                qlog(.error, "Account: ✗ PublishDevice 失敗 — \(error)")
            }
        }
    }

    /// `PublishDeviceRequest` を組み立てる。
    ///
    /// 可視性は 1 = 自分の他端末、2 = 連絡先。
    /// `contact` は 2 = `CONTACT_GOOGLE_CONTACT`。
    static func buildPublishRequest(
        deviceId: String, displayName: String, certificates: [LocalCertificate]
    ) -> NearbyPublishDeviceRequest {
        var device = NearbyDevice()
        device.name = "devices/\(deviceId)"
        device.displayName = displayName
        device.contact = 2

        for (visibility, forSelf) in [(Int32(1), true), (Int32(2), false)] {
            var group = NearbyPerVisibilityCredentials()
            group.visibility = visibility
            group.sharedCredentials = certificates
                .filter { $0.forSelfShare == forSelf }
                .compactMap { certificate in
                    guard let published = certificate.toPublicCertificate(),
                          let data = try? published.serializedData() else { return nil }
                    var credential = NearbyOutgoingSharedCredential()
                    // 上流は HighwayFingerprint64(secret_id)。鍵定数が読めないので、
                    // secret_id の先頭 8 バイトを入れて通るかを見る。
                    credential.id = Self.int64Prefix(certificate.secretId)
                    credential.dataType = 1
                    credential.data = data
                    var stamp = SwiftProtobuf.Google_Protobuf_Timestamp()
                    stamp.seconds = certificate.endTime
                    credential.expirationTime = stamp
                    return credential
                }
            device.perVisibilitySharedCredentials.append(group)
        }

        return NearbyPublishDeviceRequest(device: device)
    }

    /// バイト列の先頭 8 バイトを `int64` として読む。
    private static func int64Prefix(_ data: Data) -> Int64 {
        var value: UInt64 = 0
        for byte in data.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(bitPattern: value)
    }




    // MARK: - 設定の初期化

    func resetConfiguration() {
        AccountConfig.resetOverrides()
        objectWillChange.send()
    }

    // MARK: - 失敗の扱い

    private func finish(with error: Error) {
        let detail: String
        if let oauthError = error as? OAuthError {
            detail = oauthError.description
        } else if let loopbackError = error as? LoopbackError {
            detail = loopbackError.description
        } else {
            detail = error.localizedDescription
        }

        lastErrorDetail = detail
        lastHTTPStatus = oauth.lastHTTPStatus
        lastRedirectURI = oauth.lastRedirectURI

        if let oauthError = error as? OAuthError, case .userCancelled = oauthError {
            status = tokens == nil ? .signedOut : .signedIn
            qlog(.info, "Account: 認可を取り消しました")
            return
        }

        status = .failed(detail)
        qlog(.error, "Account: ✗ \(detail)")

        // 次に何を試せばよいかを、ログの中で言い切っておく。
        if detail.contains("redirect_uri_mismatch") {
            let other: AccountRedirectMode = redirectMode == .loopback ? .customScheme : .loopback
            qlog(.warn, "Account: → リダイレクト方式を「\(other.label)」に変えて再試行してください")
        }
        if detail.contains("invalid_client") {
            qlog(.warn, "Account: → client_secret が要るクライアントかもしれません。設定欄に入れて再試行してください")
        }
        if detail.contains("invalid_scope") || detail.contains("access_denied") {
            qlog(.warn, "Account: → この 1P スコープは外部クライアントに降りない可能性があります。第1段はここで終わりです")
        }
    }
}
