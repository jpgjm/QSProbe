//
//  DeviceNameStore.swift
//  QSProbe
//
//  相手に見せる端末名を持つ層。
//
//  ## なぜ要るか
//
//  iOS 16 以降、`UIDevice.current.name` は実際の端末名を返さない。
//  プライバシー保護のため「iPad」「iPhone」といった機種名に丸められる。
//  設定で付けた名前を読むには特別な権限が要り、通常のアプリでは取れない。
//
//  そのため、名前は**アプリ側で持つしかない**。QuickDrop が名前を変えられるのも
//  同じ理由で、OS から取っているのではなく自分で保持している。
//
//  ## どこに効くか
//
//  同じ名前が 3 か所に載る。ばらばらだと相手の画面で食い違うので、
//  1 か所にまとめて全部から参照する。
//
//  | 場所 | いつ相手に伝わるか |
//  |---|---|
//  | mDNS の広告 (`EndpointInfo`) | 相手が探しているとき |
//  | `CONNECTION_REQUEST` の `endpoint_info` | こちらから送るとき |
//  | 証明書の `EncryptedMetadata.device_name` | アカウント経由 (登録済みなら) |
//
//  前の 2 つは変えた瞬間に効く。3 つ目は**証明書を作り直して登録し直す**まで
//  変わらない。Google のサーバに置いてある値だから。
//

import Foundation
import UIKit

@MainActor
final class DeviceNameStore: ObservableObject {

    static let shared = DeviceNameStore()

    private static let defaultsKey = "QSProbe.deviceName"

    /// ユーザーが決めた名前。空なら OS の値を使う。
    @Published var customName: String {
        didSet {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.defaultsKey)
            }
        }
    }

    private init() {
        customName = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
    }

    /// 実際に相手へ見せる名前。
    ///
    /// Quick Share の相互運用のため、UTF-8 で収まる長さに切り詰める。
    var effectiveName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? UIDevice.current.name : trimmed
        return EndpointInfo.clampName(base)
    }

    /// OS から取れる名前。iOS 16 以降は機種名に丸められる。
    var systemName: String { UIDevice.current.name }

    /// ユーザーが名前を決めているか。
    var isCustomised: Bool {
        !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
