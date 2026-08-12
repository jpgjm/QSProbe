//
//  QuickShareMdns.swift
//  QSProbe
//
//  Bada の `discovery-android/.../QuickShareMdns.kt` に対応。
//  ここに並ぶ値はすべて「Google の実装とバイト単位で一致していなければ
//  ならない」ものであり、ローカルで発明した定数は一つも無い。
//

import Foundation

enum QuickShareMdns {

    /// サービスタイプの表記ゆれ。
    ///
    /// - `withTrailingDot`: `NSNetService` のドキュメントが要求する絶対名形式。
    ///   QuickDrop (App Store 配布・動作実績あり) はこちらを使っている。
    /// - `withoutTrailingDot`: Android の `NsdManager` が要求する形式。
    ///   `NSBonjourServices` の Apple ドキュメント例もこちら。
    ///
    /// **実測の結論: どちらでも publish も browse も成功する。**
    /// 当初 v1 の失敗原因をこの表記の違いだと推測したが誤りで、
    /// 真因は LiveContainer のホスト側 `NSBonjourServices` 許可リストに
    /// `_FC9F5ED42C8A._tcp` が無かったことだった。
    /// 切り替えは診断手段として残してあるだけで、既定値のままで問題ない。
    enum ServiceTypeForm: String, CaseIterable, Identifiable {
        case withTrailingDot = "末尾ドット有り"
        case withoutTrailingDot = "末尾ドット無し"

        var id: String { rawValue }

        var value: String {
            switch self {
            case .withTrailingDot: return "_FC9F5ED42C8A._tcp."
            case .withoutTrailingDot: return "_FC9F5ED42C8A._tcp"
            }
        }
    }

    /// 既定値。QuickDrop と同じ末尾ドット有り (どちらでも動く)。
    static let serviceType = ServiceTypeForm.withTrailingDot.value

    /// インスタンス名の生バイト長 (base64 前)。
    static let instanceNameRawLength = 10

    /// エンドポイント ID のバイト数。
    static let endpointIdLength = 4

    /// インスタンス名の先頭バイト = Nearby Connections の PCP マーカー。
    static let pcpByte: UInt8 = 0x23

    /// `SHA-256("NearbySharing")` の先頭 3 バイト。
    static let serviceIdHashPrefix: [UInt8] = [0xFC, 0x9F, 0x5E]

    /// TXT キー: URL-safe base64 の EndpointInfo。
    static let txtKeyEndpointInfo = "n"

    /// TXT キー: ドット区切り IPv4 アドレス。
    /// Samsung の LAN リゾルバはこれが無い候補を無視することがある。
    static let txtKeyIPv4 = "IPv4"

    /// TXT キー: Wi-Fi チャンネル周波数 (MHz)。
    static let txtKeyWifiFrequency = "f"

    /// エンドポイント ID に使う英数字。
    static let endpointIdAlphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8
    )

    /// ランダムな 4 バイトのエンドポイント ID を生成する。
    static func randomEndpointId() -> [UInt8] {
        (0..<endpointIdLength).map { _ in
            endpointIdAlphabet.randomElement()!
        }
    }

    /// mDNS のサービスインスタンス名を組み立てる。
    ///
    /// ```
    /// [ 0x23 | endpointId[4] | 0xFC 0x9F 0x5E | 0x00 0x00 ]  → URL-safe base64
    /// ```
    static func instanceName(endpointId: [UInt8]) -> String {
        precondition(endpointId.count == endpointIdLength)
        var raw: [UInt8] = [pcpByte]
        raw.append(contentsOf: endpointId)
        raw.append(contentsOf: serviceIdHashPrefix)
        raw.append(contentsOf: [0x00, 0x00])
        precondition(raw.count == instanceNameRawLength)
        return Base64Url.encode(Data(raw))
    }
}
