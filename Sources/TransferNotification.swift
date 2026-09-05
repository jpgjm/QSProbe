//
//  TransferNotification.swift
//  QSProbe
//
//  バックグラウンドで転送が終わったことを知らせるローカル通知。
//
//  ## なぜ必要か
//
//  `BGContinuedProcessingTask` が出すシステム UI は、タスクを閉じた瞬間に
//  消える。転送が終わったことは画面から分からない。実際のログでは
//  00:52:32 に送信が完了し、ユーザーが前面に戻ったのは 01:02:39 だった。
//  10 分のあいだ「終わったのか失敗したのか」を確かめる手段が無い。
//
//  ## 前面では出ない
//
//  `UNUserNotificationCenterDelegate` を実装していないので、アプリが前面に
//  いるあいだ iOS は通知を握り潰す。画面を見ているのにバナーが出る、という
//  邪魔にはならない。バックグラウンドとロック画面でだけ出る。
//
//  ## 権限
//
//  アプリを開いた最初に要求する。転送を始めた瞬間に訊くと、相手の同意待ちや
//  接続確立と権限ダイアログが重なって操作の邪魔になる。起動時に一度だけ
//  済ませておけば、実際の転送はダイアログに邪魔されない。
//  拒否されても転送そのものには何の影響も無い。
//

import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

enum TransferNotification {

    private static let categoryIdentifier = "QSProbe.transfer.completed"

    /// 同意待ちの通知。
    ///
    /// **ボタンは付けない。** 承諾/拒否を通知から直接押せるようにすると、
    /// PIN を確認せずに受け入れられる導線ができてしまう。ロック画面の
    /// プレビュー設定次第で本文が隠れるため、通知に PIN を載せても
    /// 「押す直前に見えている」保証が無い。
    ///
    /// よってこの通知の役目は**気付かせて前面へ戻すことだけ**。判断は
    /// これまでどおり同意シートで、PIN を見ながら行う。
    private static let consentCategoryIdentifier = "QSProbe.transfer.consent"

    /// 同意待ち通知の識別子。固定にしてあるので、続けて出すと差し替わる。
    /// 同意が済んだら取り下げるためにも使う。
    private static let consentIdentifier = "QSProbe.transfer.consent.pending"

    /// 権限要求は 1 プロセスに 1 回で足りる。
    /// (システム側も 2 回目以降はダイアログを出さずに現在の状態を返す)
    private static var authorizationRequested = false

    /// アプリ起動時に 1 度だけ呼ぶ。まだ訊いていなければ通知の許可を求める。
    static func prepare() {
        guard !authorizationRequested else { return }
        authorizationRequested = true

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                qlog(.warn, "通知: 権限の要求に失敗しました — \(error.localizedDescription)")
            } else {
                qlog(.info, "通知: 権限 = \(granted ? "許可" : "拒否")")
            }
        }
    }

    /// 転送が終わったことを知らせる。
    ///
    /// - Parameters:
    ///   - title: 「送信が完了しました」など。
    ///   - body: ファイル名や件数。
    static func notifyCompleted(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        // trigger = nil で即時配信。
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                qlog(.warn, "通知: 配信に失敗しました — \(error.localizedDescription)")
            } else {
                // 実際に画面へ出たかまでは分からない。前面にいるあいだは
                // iOS が握り潰すので、その場合も「出しました」になる。
                qlog(.info, "通知: 完了通知を出しました — \(title)")
            }
        }
    }

    // MARK: - 同意待ち

    /// 背面で受信リクエストが来たことを知らせる。
    ///
    /// PIN は載せない (上の `consentCategoryIdentifier` の説明を参照)。
    /// 出すのは背面にいるときだけ。前面なら同意シートが既に出ているので、
    /// 通知センターにゴミを残さないために送らない。
    ///
    /// - Parameters:
    ///   - peerName: 送信元のデバイス名。hidden なら nil。
    ///   - itemCount: ファイルとテキストの合計件数。
    @MainActor
    static func notifyConsentRequired(peerName: String?, itemCount: Int) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else {
            qlog(.info, "通知: 前面なので同意待ちの通知は出しません")
            return
        }
        #endif

        let from = peerName ?? "不明な送信元"
        let content = UNMutableNotificationContent()
        content.title = "受信リクエストが届きました"
        content.body = "\(from) から \(itemCount) 件 — タップして確認コードを照合してください"
        content.sound = .default
        content.categoryIdentifier = consentCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: consentIdentifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                qlog(.warn, "通知: 同意待ちの通知を出せませんでした — \(error.localizedDescription)")
            } else {
                qlog(.ok, "通知: ★ 同意待ちを知らせました — \(from) / \(itemCount) 件")
            }
        }
    }

    /// 同意待ち通知を取り下げる。
    ///
    /// 承諾・拒否・失敗・切断のいずれでも呼ぶこと。放置すると、もう応答
    /// できない転送の通知が通知センターに残り続ける。
    static func clearConsentRequired() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [consentIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [consentIdentifier])
    }

    /// 完了通知の本文を組み立てる。
    ///
    /// 1 件ならファイル名、複数件なら件数と合計サイズ。
    static func summary(names: [String], totalBytes: Int64) -> String {
        let size = ByteFormat.short(totalBytes)

        switch names.count {
        case 0:
            return size
        case 1:
            return "\(names[0]) — \(size)"
        default:
            return "\(names.count) 件 — \(size)"
        }
    }
}
