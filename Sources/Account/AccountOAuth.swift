//
//  AccountOAuth.swift
//  QSProbe — 実験機能 / アカウント連携 (第1段)
//
//  Google の OAuth 2.0 認可コードフロー (PKCE つき) を手書きで通します。
//
//  ```
//  ① code_verifier / code_challenge を作る
//  ② 認可画面を ASWebAuthenticationSession で開く
//  ③ リダイレクトを受け取る
//       カスタムスキーム: ASWebAuthenticationSession が拾う
//       ループバック    : LoopbackRedirectServer が拾う
//  ④ 認可コードを access_token / refresh_token に交換する
//  ```
//
//  ## 第1段でいちばん知りたいこと
//
//  **`nearbysharing-pa` という 1P スコープの同意画面が出るか**です。
//  ここで弾かれるなら、以降の段は成立しません。そのため、失敗したときの
//  Google からの応答 (`error` / `error_description` / HTTP ステータス) を
//  取りこぼさずログに残すことを最優先にしています。
//
//  ## 2 つのリダイレクト方式
//
//  この client_id がコンソール上でどの種別として登録されているかは
//  バイナリから読み取れません。iOS 型ならカスタムスキーム、デスクトップ型なら
//  ループバックしか通らないため、両方を用意して実機で試し分けます。
//  `redirect_uri_mismatch` が返るなら、もう一方を試す合図です。
//
//  ## client_secret について
//
//  デスクトップ型のクライアントはトークン交換で `client_secret` を要求します
//  (「秘密」とは名ばかりで配布物に埋まっている類のもの)。バイナリから
//  取れていないので既定では送りません。`invalid_client` が返るようなら、
//  画面から入れて再試行できます。
//

import Foundation
import UIKit
import AuthenticationServices

enum OAuthError: Error, CustomStringConvertible {

    case badConfiguration(String)
    case noPresentationAnchor
    case userCancelled
    case authorizationDenied(error: String, description: String?)
    case stateMismatch
    case missingCode
    case httpFailure(status: Int, body: String)
    case malformedResponse(String)
    case transport(String)
    case noRefreshToken

    var description: String {
        switch self {
        case .badConfiguration(let detail):
            return "設定が不正です: \(detail)"
        case .noPresentationAnchor:
            return "認可画面を出す土台 (ウインドウ) が見つかりませんでした"
        case .userCancelled:
            return "認可を取り消しました"
        case .authorizationDenied(let error, let detail):
            if let detail, !detail.isEmpty {
                return "Google が認可を拒否しました: \(error) — \(detail)"
            }
            return "Google が認可を拒否しました: \(error)"
        case .stateMismatch:
            return "state が一致しません (応答が別の要求のものです)"
        case .missingCode:
            return "応答に認可コードが含まれていません"
        case .httpFailure(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "応答を解釈できませんでした: \(detail)"
        case .transport(let detail):
            return "通信に失敗しました: \(detail)"
        case .noRefreshToken:
            return "refresh_token がないので更新できません"
        }
    }
}

/// `ASWebAuthenticationSession` に土台のウインドウを渡すだけの入れ物。
///
/// ウインドウはメインアクター上で取得したものを保持しておき、問い合わせには
/// それを返すだけにしてあります。こうすると、この型自体はどのスレッドから
/// 呼ばれても UIKit に触りません。
final class AuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {

    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

@MainActor
final class AccountOAuth {

    /// 直近のやりとりの記録 (画面の診断表示用。トークン本体は入れない)。
    private(set) var lastHTTPStatus: Int?
    private(set) var lastServerMessage: String?
    private(set) var lastRedirectURI: String?

    private var session: ASWebAuthenticationSession?
    private var loopback: LoopbackRedirectServer?
    private var anchorProvider: AuthAnchorProvider?

    // MARK: - 認可

    func authorize(mode: AccountRedirectMode, ephemeral: Bool) async throws -> AccountTokens {
        lastHTTPStatus = nil
        lastServerMessage = nil

        guard let anchor = Self.keyWindow() else {
            throw OAuthError.noPresentationAnchor
        }

        // 資格情報はコードに無いので、未設定なら何も始まらない。
        guard AccountConfig.isConfigured else {
            let missing = AccountConfig.missingSettings.joined(separator: " / ")
            throw OAuthError.badConfiguration(
                "\(missing) が未設定です。接続先の設定から読み込んでください"
            )
        }

        let verifier = Pkce.randomURLSafeString(length: 64)
        let challenge = Pkce.challenge(for: verifier)
        let state = Pkce.randomURLSafeString(length: 24)

        // --- リダイレクト先を決める ---------------------------------------
        let redirectURI: String
        var server: LoopbackRedirectServer?

        switch mode {
        case .customScheme:
            redirectURI = AccountConfig.customSchemeRedirectURI

        case .loopback:
            let newServer = LoopbackRedirectServer()
            do {
                let port = try await newServer.start()
                server = newServer
                loopback = newServer
                redirectURI = AccountConfig.loopbackRedirectURI(port: port)
            } catch {
                // 待ち受けに失敗したときも、握った資源は必ず返す。
                newServer.stop()
                throw error
            }
        }
        defer {
            server?.stop()
            loopback = nil
        }

        lastRedirectURI = redirectURI

        // --- 認可 URL を組み立てる ---------------------------------------
        guard var components = URLComponents(
            url: AccountConfig.authEndpoint, resolvingAgainstBaseURL: false
        ) else {
            throw OAuthError.badConfiguration("認可エンドポイントを解釈できません")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AccountConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AccountConfig.scopeString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // 毎回同意画面を出す。第1段の目的が「同意画面が出るか」なので、
            // 2 回目以降に省略されると確認にならない。refresh_token も確実に来る。
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        guard let authURL = components.url else {
            throw OAuthError.badConfiguration("認可 URL を組み立てられません")
        }

        qlog(.info, "Account: 認可を開始します (\(mode.label))")
        qlog(.info, "Account:   redirect_uri = \(redirectURI)")
        qlog(.info, "Account:   scope = \(AccountConfig.scopeString)")
        qlog(.info, "Account:   URL = \(authURL.absoluteString)")

        // --- 認可画面を出してリダイレクトを待つ ---------------------------
        let provider = AuthAnchorProvider(anchor: anchor)
        anchorProvider = provider

        let callbackURL: URL
        switch mode {
        case .customScheme:
            callbackURL = try await runWebAuth(
                url: authURL,
                callbackScheme: AccountConfig.reversedClientId,
                ephemeral: ephemeral,
                provider: provider,
                loopback: nil
            )
        case .loopback:
            callbackURL = try await runWebAuth(
                url: authURL,
                // ループバックでは使われない。何かしら渡す必要があるだけ。
                callbackScheme: "qsprobe-loopback-unused",
                ephemeral: ephemeral,
                provider: provider,
                loopback: server
            )
        }

        // --- 応答を読む ---------------------------------------------------
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let error = value("error") {
            let detail = value("error_description")
            lastServerMessage = [error, detail].compactMap { $0 }.joined(separator: " — ")
            qlog(.error, "Account: ✗ 認可が拒否されました — \(lastServerMessage ?? error)")
            throw OAuthError.authorizationDenied(error: error, description: detail)
        }

        guard let returnedState = value("state"), returnedState == state else {
            qlog(.error, "Account: ✗ state が一致しません")
            throw OAuthError.stateMismatch
        }

        guard let code = value("code"), !code.isEmpty else {
            qlog(.error, "Account: ✗ 認可コードがありません")
            throw OAuthError.missingCode
        }

        qlog(.ok, "Account: ★ 同意画面を通過し、認可コードを受け取りました (\(code.count) 文字)")

        // --- トークン交換 -------------------------------------------------
        return try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
    }

    // MARK: - ブラウザの起動

    private func runWebAuth(
        url: URL,
        callbackScheme: String,
        ephemeral: Bool,
        provider: AuthAnchorProvider,
        loopback: LoopbackRedirectServer?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<URL>(continuation)

            let newSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                // ループバック方式では、こちらは基本「中断」のときだけ来る。
                if let callbackURL {
                    box.resume(returning: callbackURL)
                    return
                }
                if let sessionError = error as? ASWebAuthenticationSessionError,
                   sessionError.code == .canceledLogin {
                    box.resume(throwing: OAuthError.userCancelled)
                    return
                }
                if let error {
                    box.resume(throwing: OAuthError.transport(error.localizedDescription))
                    return
                }
                box.resume(throwing: OAuthError.missingCode)
            }

            newSession.presentationContextProvider = provider
            newSession.prefersEphemeralWebBrowserSession = ephemeral
            session = newSession

            // ループバック方式は、着信したらこちらが先に決着させる。
            loopback?.onRedirect = { redirectURL in
                box.resume(returning: redirectURL)
                newSession.cancel()
            }
            loopback?.onFailure = { detail in
                box.resume(throwing: OAuthError.transport(detail))
                newSession.cancel()
            }

            if !newSession.start() {
                box.resume(throwing: OAuthError.transport(
                    "ASWebAuthenticationSession を開始できませんでした"
                ))
            }
        }
    }

    // MARK: - トークン交換

    private func exchange(
        code: String, verifier: String, redirectURI: String
    ) async throws -> AccountTokens {
        var form: [String: String] = [
            "code": code,
            "client_id": AccountConfig.clientId,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        if let secret = AccountConfig.clientSecret {
            form["client_secret"] = secret
            qlog(.info, "Account: client_secret を添えて交換します")
        }

        qlog(.info, "Account: トークン交換を要求します")
        let response = try await post(to: AccountConfig.tokenEndpoint, form: form)

        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw OAuthError.malformedResponse("access_token がありません")
        }

        let tokens = AccountTokens(
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            scope: response.scope,
            tokenType: response.tokenType,
            expiresAt: response.expiresIn.map { Date().addingTimeInterval($0) },
            obtainedAt: Date()
        )

        qlog(.ok, "Account: ★ アクセストークンを取得しました")
        qlog(.info, "Account:   有効期限 = \(tokens.expiryText)")
        qlog(.info, "Account:   refresh_token = \(tokens.refreshToken == nil ? "無し" : "有り")")
        qlog(.info, "Account:   許可されたスコープ = \(response.scope ?? "(応答に含まれず)")")

        // 要求したスコープが削られていないかを確かめる。
        if let granted = response.scope {
            let grantedSet = Set(granted.split(separator: " ").map(String.init))
            let missing = AccountConfig.scopes.filter { !grantedSet.contains($0) }
            if !missing.isEmpty {
                qlog(.warn, "Account: ⚠ 要求したのに降りなかったスコープ = \(missing.joined(separator: ", "))")
            }
        }

        return tokens
    }

    // MARK: - 更新

    func refresh(_ tokens: AccountTokens) async throws -> AccountTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw OAuthError.noRefreshToken
        }

        var form: [String: String] = [
            "client_id": AccountConfig.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = AccountConfig.clientSecret {
            form["client_secret"] = secret
        }

        qlog(.info, "Account: トークンの更新を要求します")
        let response = try await post(to: AccountConfig.tokenEndpoint, form: form)

        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw OAuthError.malformedResponse("access_token がありません")
        }

        var updated = tokens
        updated.accessToken = accessToken
        // 更新では refresh_token が返らないのが普通。返ってきたときだけ差し替える。
        if let newRefresh = response.refreshToken { updated.refreshToken = newRefresh }
        if let scope = response.scope { updated.scope = scope }
        if let tokenType = response.tokenType { updated.tokenType = tokenType }
        updated.expiresAt = response.expiresIn.map { Date().addingTimeInterval($0) }
        updated.obtainedAt = Date()

        qlog(.ok, "Account: ★ トークンを更新しました (有効期限 \(updated.expiryText))")
        return updated
    }

    // MARK: - 連携解除

    /// Google 側の許可そのものを取り消す。失敗しても致命ではないので投げない。
    func revoke(_ tokens: AccountTokens) async {
        let target = tokens.refreshToken ?? tokens.accessToken
        guard var components = URLComponents(
            url: AccountConfig.revokeEndpoint, resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "token", value: target)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AccountConfig.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                qlog(.ok, "Account: ★ Google 側の連携を解除しました")
            } else {
                qlog(.warn, "Account: 連携解除の応答が HTTP \(status) でした")
            }
        } catch {
            qlog(.warn, "Account: 連携解除に失敗しました — \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String?
        let tokenType: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
            case error
            case errorDescription = "error_description"
        }
    }

    private func post(to url: URL, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(AccountConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncode(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            lastServerMessage = error.localizedDescription
            qlog(.error, "Account: ✗ 通信に失敗しました — \(error.localizedDescription)")
            throw OAuthError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        lastHTTPStatus = status
        qlog(.info, "Account: 応答 HTTP \(status) (\(data.count) バイト)")

        let decoded: TokenResponse?
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            decoded = nil
        }

        guard status == 200 else {
            // 失敗時だけ本文を残す。成功時の本文にはトークンが入っているため出さない。
            let body = String(data: data, encoding: .utf8) ?? "(本文を読めません)"
            let trimmed = body.count > 800 ? String(body.prefix(800)) + "…" : body
            let message = [decoded?.error, decoded?.errorDescription]
                .compactMap { $0 }
                .joined(separator: " — ")
            lastServerMessage = message.isEmpty ? trimmed : message
            qlog(.error, "Account: ✗ HTTP \(status) — \(trimmed)")
            throw OAuthError.httpFailure(status: status, body: trimmed)
        }

        guard let decoded else {
            lastServerMessage = "JSON として読めません"
            throw OAuthError.malformedResponse("JSON として読めません")
        }
        if let error = decoded.error {
            lastServerMessage = [error, decoded.errorDescription]
                .compactMap { $0 }
                .joined(separator: " — ")
            throw OAuthError.authorizationDenied(
                error: error, description: decoded.errorDescription
            )
        }
        lastServerMessage = nil
        return decoded
    }

    /// `application/x-www-form-urlencoded`。
    /// `urlQueryAllowed` は `+` や `&` を通してしまうので、unreserved だけ残す。
    private static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let pairs: [String] = form.map { pair in
            let key = pair.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.key
            let value = pair.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.value
            return "\(key)=\(value)"
        }
        return Data(pairs.sorted().joined(separator: "&").utf8)
    }

    // MARK: - ウインドウ

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return key
        }
        return scenes.flatMap { $0.windows }.first
    }
}
