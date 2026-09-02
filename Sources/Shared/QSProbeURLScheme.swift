//
//  QSProbeURLScheme.swift
//  QSProbe
//
//  Share Extension がホストアプリを起こすための URL スキーム。
//  拡張とホストの両方から参照するので、文字列を 1 か所に置く。
//
//  URL には何も情報を載せない。渡すファイルは共有コンテナの
//  `ShareInbox/` に置いてあり、ホストはそこを走査して拾う。
//  URL は「起きて、受信箱を見ろ」という合図だけの役割。
//
//  こうしておくと、ホストが起動していない間に共有されたぶんも
//  起動時の走査だけで拾える。URL を取りこぼしても失われない。
//

import Foundation

enum QSProbeURLScheme {

    /// `project.yml` の CFBundleURLSchemes と一致させること。
    static let scheme = "qsprobe"

    /// 共有シートから来たことを示すホスト名。
    static let shareHost = "share"

    /// この URL を処理すべきか。
    static func isShareCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == shareHost
    }
}
