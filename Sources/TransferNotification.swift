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

enum TransferNotification {

    private static let categoryIdentifier = "QSProbe.transfer.completed"

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
