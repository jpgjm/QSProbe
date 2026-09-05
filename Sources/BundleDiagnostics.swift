//
//  BundleDiagnostics.swift
//  QSProbe
//
//  v2 で追加。
//  「Info.plist のキーが本当にアプリバンドルに焼き込まれているか」を
//  実行時に読み出して画面に出す。これで
//
//    (A) キー自体が欠けている            → ビルド設定の問題
//    (B) キーはあるが権限が下りていない  → TCC の問題
//
//  を切り分けられる。
//
//  【限界】LiveContainer のようにゲストアプリをホストのプロセス内で動かす
//  環境では、この診断だけでは足りない。`Bundle.main` はゲストのバンドルを
//  返すのでここは緑になる一方、Bonjour のサービスタイプ照合は**ホスト側の
//  NSBonjourServices 許可リスト**に対して行われるため、
//  `_FC9F5ED42C8A._tcp` が含まれていなければ拒否される。
//  (Local Network や写真ライブラリの「権限」自体は LiveContainer でも取れる。
//   マージされないのはサービスタイプの許可リストだけ)
//  ⓪ が全部緑なのに -72008 / -65555 が出る場合はこれを疑うこと。
//  詳細と回避策は docs/LiveContainer-patch.md を参照。
//

import Foundation

enum BundleDiagnostics {

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "(取得できません)"
    }

    static var localNetworkUsageDescription: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
    }

    static var bonjourServices: [String]? {
        Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
    }

    /// インストール済みバンドルに焼き込まれている BGTask の許可識別子。
    ///
    /// **署名後の実物**を読んでいるので、SideStore がこのキーを書き換えて
    /// いるかどうかがここで分かる。素の `com.anony.qsprobe.transfer` が
    /// そのまま残っていれば、書き換えていない証拠になる。
    static var permittedBGTaskIdentifiers: [String]? {
        Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
    }

    /// 識別子が実行時の bundle ID 配下にあるか。
    ///
    /// システムがタスクを起動するときに見ているのはこの条件で、
    /// `register()` は見ていない (Info.plist の文字列照合だけ)。
    static func isUnderRuntimeBundleID(_ identifier: String) -> Bool {
        guard let runtime = Bundle.main.bundleIdentifier else { return false }
        return identifier == runtime || identifier.hasPrefix(runtime + ".")
    }

    /// 起動時に一括でログへ吐く。
    static func dumpToLog() {
        qlog(.info, "Bundle ID = \(bundleIdentifier)")

        if let desc = localNetworkUsageDescription {
            qlog(.ok, "NSLocalNetworkUsageDescription = 有り (\(desc.count) 文字)")
        } else {
            qlog(.error, "NSLocalNetworkUsageDescription = ✗ 欠落")
        }

        if let services = bonjourServices, !services.isEmpty {
            qlog(.ok, "NSBonjourServices = \(services)")
        } else {
            qlog(.error, "NSBonjourServices = ✗ 欠落または空")
        }
    }
}

// MARK: - エラーコードの人間可読化

enum NetErrorNames {

    /// NSNetServicesError の定数名。
    static func netServices(_ code: Int) -> String {
        switch code {
        case -72000: return "NSNetServicesUnknownError"
        case -72001: return "NSNetServicesCollisionError"
        case -72002: return "NSNetServicesNotFoundError"
        case -72003: return "NSNetServicesActivityInProgress"
        case -72004: return "NSNetServicesBadArgumentError"
        case -72005: return "NSNetServicesCancelledError"
        case -72006: return "NSNetServicesInvalidError"
        case -72007: return "NSNetServicesTimeoutError"
        case -72008: return "NSNetServicesMissingRequiredConfigurationError"
        default: return "不明 (\(code))"
        }
    }

    /// NSNetServicesError の意味と、疑うべき箇所。
    static func netServicesHint(_ code: Int) -> String {
        switch code {
        case -72008:
            return "このサービスタイプが実行環境の NSBonjourServices 許可リストに無い。"
                + "⓪ が緑でもこのエラーが出る場合、LiveContainer など"
                + "別アプリのプロセス内で動かしている可能性が高い"
                + "(ホスト側の許可リストが参照され、ゲスト側の宣言はマージされないため)。"
                + "SideStore で直接インストールするか、docs/LiveContainer-patch.md を参照。"
        case -72001:
            return "同じインスタンス名が LAN 上で衝突している。"
        case -72004:
            return "タイプ名かポート番号が不正。"
        default:
            return ""
        }
    }

    /// DNSServiceErrorType の主要な定数名。
    static func dnssd(_ code: Int) -> String {
        switch code {
        case -65535: return "kDNSServiceErr_Unknown"
        case -65540: return "kDNSServiceErr_BadParam"
        case -65548: return "kDNSServiceErr_NameConflict"
        case -65555: return "kDNSServiceErr_NoAuth (ローカルネットワーク権限が無いか、サービスタイプが許可リストに無い)"
        case -65563: return "kDNSServiceErr_ServiceNotRunning"
        case -65570: return "kDNSServiceErr_PolicyDenied"
        case -65572: return "kDNSServiceErr_NoSubscribers"
        default: return "不明 (\(code))"
        }
    }
}
