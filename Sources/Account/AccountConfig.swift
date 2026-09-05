//
//  AccountConfig.swift
//  QSProbe — 実験機能 / アカウント連携 (第1段: OAuth のみ)
//
//  ここにある値はすべて `nearby_share.exe` のバイナリから読み取ったものです。
//  **コードにハードコードしない**という設計方針に従い、既定値は持ちつつ
//  `UserDefaults` で実行時に上書きできるようにしてあります。
//
//  iOS では `defaults write` が使えないため、上書きは画面
//  (実験機能 → 接続先の設定) から行います。Google 側で塞がれたときに、
//  ビルドし直さずに別の値を試せるようにするのが目的です。
//
//  この enum は**設定を読むだけ**で、通信は一切しません。
//

import Foundation

/// 認可コードを受け取る経路。
///
/// どちらが通るかは、この client\_id が Google のコンソール上で
/// **どの種別のクライアントとして登録されているか**で決まります。
/// バイナリからは種別まで読み取れないため、両方を用意して実機で試します。
enum AccountRedirectMode: String, CaseIterable, Identifiable {

    /// `com.googleusercontent.apps.<client>:/oauth2redirect`
    ///
    /// iOS / Android 型のクライアントで使える形。`ASWebAuthenticationSession`
    /// がそのまま受け取れるので、通るならこちらが素直です。
    case customScheme

    /// `http://127.0.0.1:<port>/oauth2redirect`
    ///
    /// デスクトップ (Windows / macOS / Linux) 型のクライアントはこちらしか
    /// 受け付けません。`nearby_share.exe` は Windows のアプリなので、
    /// **本命はこちら**だと考えています。端末内に一時的な HTTP サーバを立て、
    /// 認可画面からのリダイレクトを自分で拾います。
    case loopback

    var id: String { rawValue }

    var label: String {
        switch self {
        case .customScheme: return "カスタムスキーム"
        case .loopback:     return "ループバック"
        }
    }

    var detail: String {
        switch self {
        case .customScheme: return "iOS / Android 型のクライアント向け"
        case .loopback:     return "デスクトップ型のクライアント向け"
        }
    }
}

enum AccountConfig {

    // MARK: - 資格情報はコードに置かない

    /// `client_id` と `client_secret` は **このリポジトリには入れない**。
    ///
    /// GitHub の push protection がこの 2 つを検出して push を拒否する。
    /// 検出器から見れば Google の OAuth 資格情報そのものであり、
    /// 実際 `nearby_share.exe` から抜いた値なので、公開リポジトリに置く筋合いも無い。
    ///
    /// 代わりに、端末側で設定として与える。取り込み口は 3 つある。
    ///
    /// 1. 「接続先の設定」の欄に直接入力する
    /// 2. 設定テキストをクリップボードから読み込む
    /// 3. 設定テキストのファイル (.txt) を選んで読み込む
    ///
    /// 値の出どころは `nearby_share.exe` で、取り出し方は
    /// `docs/account-linking.md` に書いてある。
    static let defaultClientId = ""

    /// このクライアントはデスクトップ型なので、トークン交換で `client_secret` が要る。
    /// 未設定なら送らない (その場合 `invalid_request` が返る)。
    static let defaultClientSecret: String? = nil

    /// `nearbysharingsdk` は**この client_id に紐づいていない**。
    /// 一緒に要求すると `restricted_client` で弾かれる (実測)。
    static let defaultScopes = [
        "https://www.googleapis.com/auth/nearbysharing-pa",
    ]

    static let defaultAuthEndpoint = "https://accounts.google.com/o/oauth2/auth"
    static let defaultTokenEndpoint = "https://oauth2.googleapis.com/token"
    static let defaultRevokeEndpoint = "https://oauth2.googleapis.com/revoke"

    /// リダイレクト先のパス部分。カスタムスキームなら `<scheme>:/oauth2redirect`、
    /// ループバックなら `http://127.0.0.1:<port>/oauth2redirect` になります。
    ///
    /// カスタムスキームは**この client_id では使えない** (`Custom scheme URI not
    /// allowed`)。ループバック一択。
    static let defaultRedirectPath = "/oauth2redirect"

    // MARK: - gRPC の宛先 (バイナリから確定)

    /// `nearby_share.exe` には gRPC の宛先が 2 つ入っている。
    ///
    /// ```
    /// nearbysharing-pa.googleapis.com   NearbySharingService (連絡先の取得)
    /// nearby.googleapis.com             NearbyService (identity) ← こちら
    /// ```
    ///
    /// どちらも `grpc_async_client_factory.cc` の中で隣り合って現れる。
    /// identity 側が `nearby.googleapis.com` だと判断した根拠は、proto の
    /// `google.api.resource` 註釈が資源名を
    /// `nearby.googleapis.com/Device` / `nearby.googleapis.com/IdentityBrokerConfig`
    /// と宣言していること。資源名の前半はその資源を持つ API のホストを指す。
    ///
    /// `nearbysharing-pa.googleapis.com` に identity のパスを投げると
    /// `UNIMPLEMENTED` が返るのも、この読みと合う。
    static let defaultGrpcHost = "nearby.googleapis.com"

    /// バイナリから**そのまま**取ったサービス名。推測ではない。
    ///
    /// `nearby_identity_grpc_async_client.cc` の周辺に、10 本のメソッドが
    /// フルパスの文字列リテラルとして並んでいる。
    static let defaultGrpcService = "google.nearby.identity.v1.NearbyService"

    /// バイナリに実在するメソッド名 (フルパスから抜いたもの)。
    static let knownMethods = [
        "PublishDevice",
        "QuerySharedCredentials",
        "GetAccountInfo",
        "MintTalismans",
        "GetIdentityBrokerConfig",
        "UpdateTalismanKey",
        "QuerySharedCredentialsWithBindingIds",
        "InitiateBinding",
        "JoinBinding",
        "DeleteBinding",
    ]

    // MARK: - UserDefaults のキー

    enum Key {
        static let clientId      = "QSProbe.account.clientId"
        static let clientSecret  = "QSProbe.account.clientSecret"
        static let scopes        = "QSProbe.account.scopes"
        static let authEndpoint  = "QSProbe.account.authEndpoint"
        static let tokenEndpoint = "QSProbe.account.tokenEndpoint"
        static let revokeEndpoint = "QSProbe.account.revokeEndpoint"

        /// 「アカウント設定を初期化」で消す対象。
        static let all: [String] = [
            clientId, clientSecret, scopes, authEndpoint, tokenEndpoint,
            revokeEndpoint,
        ]
    }

    private static var store: UserDefaults { .standard }

    // MARK: - 読み取り

    private static func string(_ key: String, _ fallback: String) -> String {
        guard let value = store.string(forKey: key),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func url(_ key: String, _ fallback: String) -> URL {
        if let raw = store.string(forKey: key),
           let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed.scheme != nil {
            return parsed
        }
        // 既定値は定数なので、ここでの強制アンラップは失敗し得ない。
        return URL(string: fallback)!
    }

    static var clientId: String { string(Key.clientId, defaultClientId) }

    /// デスクトップ型のクライアントはトークン交換で `client_secret` を要求します。
    /// バイナリから取れていないので既定は空。要求されたら画面から入れられます。
    static var clientSecret: String? {
        guard let value = store.string(forKey: Key.clientSecret) else {
            return defaultClientSecret
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultClientSecret : trimmed
    }

    /// 認可を始められる状態か。`client_id` が無ければ何もできない。
    static var isConfigured: Bool {
        !clientId.isEmpty
    }

    /// 足りていないものを日本語で並べる。画面にそのまま出す。
    static var missingSettings: [String] {
        var missing: [String] = []
        if clientId.isEmpty { missing.append("client_id") }
        if clientSecret == nil { missing.append("client_secret") }
        return missing
    }

    static var scopes: [String] {
        if let raw = store.string(forKey: Key.scopes) {
            let parts = raw
                .components(separatedBy: CharacterSet(charactersIn: " \n\t,"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts }
        }
        return defaultScopes
    }

    static var scopeString: String { scopes.joined(separator: " ") }

    static var authEndpoint: URL { url(Key.authEndpoint, defaultAuthEndpoint) }
    static var tokenEndpoint: URL { url(Key.tokenEndpoint, defaultTokenEndpoint) }
    static var revokeEndpoint: URL { url(Key.revokeEndpoint, defaultRevokeEndpoint) }

    /// これらは実測で確定しているので、上書きの口を持たない。
    ///
    /// 入力欄を残しても迷わせるだけで、変えて通る値が他に無い。
    /// Google 側の仕様が変われば、ここを直してビルドし直す。
    static var redirectPath: String { defaultRedirectPath }
    static var grpcHost: String { defaultGrpcHost }
    static var grpcService: String { defaultGrpcService }

    // MARK: - リダイレクト URI の組み立て

    /// `com.googleusercontent.apps.<client_id から末尾を除いた部分>`
    ///
    /// Google が iOS クライアントに割り当てる「逆順クライアント ID」。
    /// **この client_id では使えない**ことが実測で確定している
    /// (`Custom scheme URI not allowed`)。切り分けの記録として残す。
    static var reversedClientId: String {
        guard !clientId.isEmpty else { return "" }
        let suffix = ".apps.googleusercontent.com"
        let base = clientId.hasSuffix(suffix)
            ? String(clientId.dropLast(suffix.count))
            : clientId
        return "com.googleusercontent.apps.\(base)"
    }

    /// カスタムスキーム方式のリダイレクト URI。スラッシュは 1 本 (Google の流儀)。
    static var customSchemeRedirectURI: String {
        "\(reversedClientId):\(redirectPath)"
    }

    /// ループバック方式のリダイレクト URI。**こちらだけが通る。**
    static func loopbackRedirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(redirectPath)"
    }

    // MARK: - その他

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    /// gRPC / トークン交換で送る User-Agent。
    static var userAgent: String {
        "QSProbe/\(appVersion) (experimental account linking)"
    }

    // MARK: - 上書きの管理

    /// 既定値から変えられているキーの一覧 (画面表示用)。
    static var overriddenKeys: [String] {
        Key.all.filter { key in
            guard let value = store.string(forKey: key) else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }


    /// 上書きをすべて消して既定値に戻す。
    static func resetOverrides() {
        for key in Key.all { store.removeObject(forKey: key) }
        qlog(.info, "Account: 接続先の設定を既定値に戻しました")
    }

    /// 画面から書き換える用。空文字なら上書きを解除する。
    static func setOverride(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.removeObject(forKey: key)
        } else {
            store.set(trimmed, forKey: key)
        }
    }

    /// 上書きされている生の値 (未設定なら空文字)。編集欄の初期値に使う。
    static func rawOverride(_ key: String) -> String {
        store.string(forKey: key) ?? ""
    }
}
