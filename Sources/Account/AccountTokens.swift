//
//  AccountTokens.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  トークンの保持と Keychain への保存。
//
//  ## 保存先を分けている理由
//
//  この機能は Google の非公開 API を叩く実験なので、**いつでも丸ごと
//  捨てられる**ようにしておく必要があります。サービス名を他と分けておけば、
//  「実験機能をやめる」ときに 1 回の `SecItemDelete` で完結します。
//
//  ## SideStore で入れ直したときの挙動
//
//  Keychain の項目はアプリのアクセスグループ (= チーム ID) に紐づきます。
//  SideStore は再署名のたびに同じ無料 Apple ID のチームを使うので通常は
//  残りますが、**アンインストール → 再インストールでは消えることがあります**。
//  読めなかったときは「未サインイン」に落ちるだけで、再認可すれば戻ります。
//

import Foundation
import Security

struct AccountTokens: Codable, Equatable {

    var accessToken: String
    var refreshToken: String?
    var scope: String?
    var tokenType: String?
    /// `expires_in` から計算した失効時刻。返ってこなければ nil。
    var expiresAt: Date?
    var obtainedAt: Date

    /// 期限切れ (1 分の余裕を見る)。期限が不明なときは「切れていない」とみなす。
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }

    /// 画面やログに出す用。トークンそのものは絶対に出さない。
    var maskedAccessToken: String {
        let count = accessToken.count
        guard count > 12 else { return "(\(count) 文字)" }
        let head = accessToken.prefix(6)
        let tail = accessToken.suffix(4)
        return "\(head)…\(tail) (\(count) 文字)"
    }

    var expiryText: String {
        guard let expiresAt else { return "不明" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        let remaining = Int(expiresAt.timeIntervalSinceNow)
        if remaining <= 0 {
            return "\(formatter.string(from: expiresAt)) (期限切れ)"
        }
        return "\(formatter.string(from: expiresAt)) (あと \(remaining / 60) 分)"
    }
}

// MARK: - Keychain

enum AccountKeychain {

    /// 他の設定と混ざらないよう、この実験専用のサービス名にする。
    static let service = "com.anony.qsprobe.account.experimental"
    private static let account = "google-oauth"

    @discardableResult
    static func save(_ tokens: AccountTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else {
            qlog(.error, "Account: トークンを符号化できませんでした")
            return false
        }

        // 追加の前に必ず消す。更新 (SecItemUpdate) は分岐が増えるだけで得がない。
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ロック解除後なら読めれば十分。バックグラウンド更新にも耐える。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            qlog(.error, "Account: Keychain への保存に失敗しました (OSStatus \(status))")
            return false
        }
        return true
    }

    static func load() -> AccountTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                qlog(.warn, "Account: Keychain の読み出しに失敗しました (OSStatus \(status))")
            }
            return nil
        }
        guard let data = item as? Data,
              let tokens = try? JSONDecoder().decode(AccountTokens.self, from: data) else {
            qlog(.warn, "Account: Keychain の内容を復元できませんでした")
            return nil
        }
        return tokens
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            qlog(.warn, "Account: Keychain の削除に失敗しました (OSStatus \(status))")
        }
    }
}
