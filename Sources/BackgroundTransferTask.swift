//
//  BackgroundTransferTask.swift
//  QSProbe
//
//  送受信のあいだ、アプリがバックグラウンドへ回っても実行を続けるための箱。
//
//  ## 何をしているか
//
//  2 段構えになっている。
//
//  | 段 | API | 効く時間 | 画面表示 |
//  |---|---|---|---|
//  | 1 | `UIApplication.beginBackgroundTask` | 約 30 秒 | 無し |
//  | 2 | `BGContinuedProcessingTask` (iOS 26+) | 転送が終わるまで | システムが進捗 UI を出す |
//
//  2 段目が起動しなければ 1 段目の約 30 秒しか無い。ログの
//  「★ 継続実行タスクが起動しました」が出ているかで、どちらの状態かが分かる。
//
//  ## 識別子まわりの経緯
//
//  実機で 3 通り試して、原因を切り分けた。
//
//  | rev | Info.plist の許可識別子 | 使った識別子 | register() | 起動 |
//  |---|---|---|---|---|
//  | 1 | `com.anony.qsprobe.transfer` (完全一致) | 同左 (固定) | true | **しない** |
//  | 2 | `com.anony.qsprobe.*` (ワイルドカード) | `<実行時bundleId>.transfer.<ms>` | **false** | — |
//  | 3 | `<各bundleId>.transfer.0`〜`.7` (完全一致 16 件) | 枠を回す | true | **する** |
//
//  分かったこと。
//
//  - **ワイルドカードが効かない。** 前方一致するはずの識別子で `register()`
//    が false を返す。候補は Info.plist に完全一致で書き並べるしかない。
//  - **原因は「識別子がアプリの bundle ID 配下に無いこと」だった。**
//    実機の bundle ID は SideStore の書き換えで
//    `com.anony.qsprobe.48A5LFNW96` になっており、rev1 の
//    `com.anony.qsprobe.transfer` はその配下ではなかった。
//    `register()` はこの点を見ていない (Info.plist の文字列照合だけ) ので
//    true を返すが、システムがタスクを起動する段階で弾かれる。
//  - **識別子の使い回しは問題にならない。** rev3 で 13 回転送し、枠 0〜7 を
//    一周して 2 周目に入っても全て起動した。`setTaskCompleted(success: false)`
//    で閉じた枠 (枠 4) の再利用でも起動した。Apple の DTS が言う
//    「同じ ID の 2 回目は動かない」は、少なくともこの環境では起きない。
//
//  よって rev4 以降は **固定の識別子 1 個**で足りる。Info.plist には
//  実行時 bundle ID 配下 (系列 1) と素の bundle ID 配下 (系列 2) の
//  2 件だけ置き、`register()` が通ったほうを採用する。
//
//  ## strategy を .fail にしている理由
//
//  `.queue` は「順番待ち」と「永久に起動しない」が区別できない。この API は
//  前面のユーザー操作を起点に即座に走るのが本来の姿なので、`.fail` にして
//  起動できない理由を投げてもらう。起動しなくても 1 段目の 30 秒は残る。
//
//  ## スレッド
//
//  main スレッド専用。`register(using: .main)` にしてあるのでハンドラも
//  main に来る。呼び出し元の 2 つのセッションはどちらも `@MainActor`。
//

import BackgroundTasks
import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class BackgroundTransferTask {

    /// どちらの向きの転送がタスクを握っているか。
    enum Role: String {
        case receiving
        case sending

        var title: String {
            switch self {
            case .receiving: return "ファイルを受信中"
            case .sending:   return "ファイルを送信中"
            }
        }
    }

    static let shared = BackgroundTransferTask()

    /// `project.yml` に書いてある素の bundle ID。SideStore が書き換える前の値。
    /// 実行時の bundle ID で登録できなかったときの第 2 候補に使う。
    private static let fallbackBundleId = "com.anony.qsprobe"

    /// ハンドラ起動までの見張り時間。本来 1 秒未満で来る。
    private static let launchTimeout: TimeInterval = 2.0

    /// システム UI の再描画は安くない。値が変わったときだけ、かつ最短 250 ms 間隔。
    private static let publishInterval: TimeInterval = 0.25

    /// 転送が終わってから実行保持を手放すまでの猶予。
    ///
    /// `setTaskCompleted` を呼んだ瞬間に実行権が消えるので、その直後に
    /// アプリがサスペンドされる。DISCONNECTION を投げた直後に閉じていた
    /// ときは、相手の FIN を受け取れずに `Connection reset by peer` になり、
    /// 後始末が前面復帰まで持ち越されていた。実測で 10 分放置された例もある。
    /// 数秒だけ延ばして、切断の往復を終えてから手放す。
    private static let disconnectGrace: TimeInterval = 3.0

    // MARK: - 状態

    /// `register()` が通った識別子。nil なら 2 段目は使えない。
    private var permittedIdentifier: String?

    private var owner: Role?
    private var onExpire: (() -> Void)?

    /// 1 段目。`.invalid` が未取得。
    private var assertionId: UIBackgroundTaskIdentifier = .invalid

    /// 2 段目。`BGContinuedProcessingTask` の名前は iOS 26 でしか書けないので、
    /// 保持は基底の `BGTask` (iOS 13+) で行い、使うときにダウンキャストする。
    private var continuedTask: BGTask?

    /// 今回の申請に使った識別子。取り下げに使う。
    private var activeIdentifier: String?

    private var launchWatchdog: DispatchWorkItem?

    /// 猶予中の後始末。予約されているあいだ `continuedTask` は生きている。
    private var pendingTeardown: DispatchWorkItem?
    private var teardownSuccess = false

    private var lastDetail = ""
    private var lastPercent = Int.min
    private var lastPublished = Date.distantPast

    private init() {}

    // MARK: - 起動時

    /// 起動時に 1 度だけ呼ぶ。`QSProbeApp.init()` から。
    ///
    /// ここで環境を吐き出し、使える識別子の系列を決めて、枠を全部登録する。
    /// 登録は「起動完了まで」の制約から `BGContinuedProcessingTask` は
    /// 外れているが、まとめてここでやっておけば二重登録の心配が無い。
    func register() {
        guard #available(iOS 26.0, *) else {
            qlog(.info, "BGTask: iOS 26 未満のため継続実行タスクは使えません "
                + "(バックグラウンドは約 30 秒まで)")
            return
        }

        // 検証モードをこの起動ぶん凍結する。既定は .auto で通常動作。
        BGTaskIdentifierProbe.freeze(mode: BGTaskIdentifierProbe.pendingMode)
        BGTaskIdentifierProbe.dumpToLog()

        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String] ?? []

        qlog(.info, "BGTask: bundleId = \(Bundle.main.bundleIdentifier ?? "(不明)")")
        qlog(.info, "BGTask: 許可識別子 = \(permitted)")
        qlog(.info, "BGTask: 低電力モード = "
            + (ProcessInfo.processInfo.isLowPowerModeEnabled ? "オン" : "オフ"))

        guard !permitted.isEmpty else {
            qlog(.error, "BGTask: BGTaskSchedulerPermittedIdentifiers が空です。"
                + "Info.plist が届いていません")
            return
        }

        // 候補を優先順に試す。register() が true を返したものを採用する。
        for candidate in Self.candidateIdentifiers() {
            let ok = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: candidate,
                using: .main
            ) { [weak self] task in
                self?.attach(task)
            }

            BGTaskIdentifierProbe.recordRegister(candidate, accepted: ok)

            if ok {
                permittedIdentifier = candidate
                qlog(.ok, "BGTask: 識別子を採用しました — \(candidate)")
                break
            }
            qlog(.info, "BGTask: \(candidate) は許可されていません。次を試します")
        }

        if permittedIdentifier == nil {
            qlog(.error, "BGTask: 使える識別子がありませんでした。"
                + "project.yml の BGTaskSchedulerPermittedIdentifiers を確認してください")
        }

        // 前のセッションが積み残した申請を消す。
        // 同じ識別子の記録が失敗のまま残っていると、次の申請が受理だけされて
        // 永久に起動しない状態になりうる。このアプリは他に BGTask を
        // 一切使っていないので全消しで問題ない。
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            guard !requests.isEmpty else { return }
            let ids = requests.map { $0.identifier }.joined(separator: ", ")
            qlog(.warn, "BGTask: 前回の積み残しを取り下げます — \(ids)")
            BGTaskScheduler.shared.cancelAllTaskRequests()
        }
    }

    /// 候補となる識別子。優先順。
    ///
    /// 1. 実行時の bundle ID 配下 (SideStore 版ではチーム ID 込み)
    /// 2. `project.yml` に書いた素の bundle ID 配下
    ///
    /// どちらも `project.yml` に完全一致で書いてある必要がある。
    /// システムは「識別子がアプリの bundle ID 配下にあること」を見るので、
    /// 1 が通る環境では必ず 1 を使う。
    ///
    /// 検証モード (`BGTaskIdentifierProbe`) が `.auto` 以外のときは、
    /// 候補を 1 つに絞る。落ちてほしい条件で本当に落ちるかを見るため、
    /// フォールバックさせてはいけない。
    private static func candidateIdentifiers() -> [String] {
        switch BGTaskIdentifierProbe.activeMode {
        case .plain:
            return [fallbackBundleId + ".transfer"]
        case .unlisted:
            return [BGTaskIdentifierProbe.unlistedIdentifier]
        case .auto:
            break
        }

        var candidates: [String] = []

        if let runtime = Bundle.main.bundleIdentifier {
            candidates.append(runtime + ".transfer")
        }

        let fallback = fallbackBundleId + ".transfer"
        if !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        return candidates
    }

    // MARK: - 開始 / 更新 / 終了

    /// 転送区間の入口。ユーザー操作の直後 (= 前面) に呼ぶこと。
    ///
    /// - Parameters:
    ///   - role: 受信か送信か。
    ///   - detail: 進捗がまだ無い段階に出す説明。
    ///   - onExpire: OS に打ち切られたとき / システム UI の停止ボタンを
    ///     押されたときに呼ばれる。転送を畳む処理を渡す。
    func begin(role: Role, detail: String, onExpire: @escaping () -> Void) {
        // 前の転送の後始末が猶予中なら、待たずに畳んでから始める。
        if pendingTeardown != nil {
            finishNow(success: teardownSuccess)
        }

        if let owner {
            if owner != role {
                // 受信と送信が同時に走る場面は想定していない。先に握った方を優先。
                qlog(.warn, "BGTask: \(owner.rawValue) が実行中のため "
                    + "\(role.rawValue) の要求は無視します")
            }
            return
        }

        self.owner = role
        self.onExpire = onExpire
        lastDetail = detail
        lastPercent = Int.min
        lastPublished = .distantPast

        holdAssertion()
        submit(title: role.title, subtitle: detail)
    }

    /// 検証用。実際の転送を伴わずに 2 段目の申請だけを試す。
    ///
    /// 識別子の A/B に Android 端末とファイルを用意するのは重いので、
    /// 通常の `begin()` / `end()` をそのまま通して申請だけを行う。
    /// 経路が本番と同じなので、結果はそのまま信用してよい。
    ///
    /// - Parameter seconds: 申請してから畳むまでの秒数。ハンドラは
    ///   本来 1 秒未満で来るので、既定の 5 秒あれば十分に見える。
    func runIdentifierProbe(seconds: TimeInterval = 5) {
        qlog(.info, "BGTask検証: 転送なしで申請だけを試します "
            + "(\(Int(seconds)) 秒後に畳みます)")

        begin(role: .sending, detail: "識別子の検証") {
            qlog(.warn, "BGTask検証: OS に打ち切られました")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.end(role: .sending)
            qlog(.info, "BGTask検証: 終了しました")
        }
    }

    /// 進捗の反映。間引きはこの中でやるので、呼び出し側は毎回投げてよい。
    ///
    /// - Parameter percent: 0〜100。負値は「進捗不明」で不定プログレスになる。
    func update(role: Role, detail: String, percent: Int) {
        guard owner == role else { return }
        guard detail != lastDetail || percent != lastPercent else { return }

        let now = Date()
        let overdue = now.timeIntervalSince(lastPublished) >= Self.publishInterval
        // 100% は間引かない。最後の 1 回が落ちるとバナーが 99% で止まって見える。
        guard overdue || percent >= 100 else { return }

        lastDetail = detail
        lastPercent = percent
        lastPublished = now

        applyToContinuedTask()
    }

    /// 転送区間の出口。成功 / 失敗 / 取り消しのいずれでも呼ぶ。
    ///
    /// すぐに実行権を手放さず、`disconnectGrace` 秒だけ延ばしてから畳む。
    /// この間に DISCONNECTION の往復とソケットの後始末が終わる。
    func end(role: Role) {
        guard owner == role else { return }

        cancelWatchdog()

        let success = currentProgressIsComplete()

        // バナーを終わった状態にしてから猶予に入る。
        if #available(iOS 26.0, *),
           let task = continuedTask as? BGContinuedProcessingTask {
            task.updateTitle(role.title, subtitle: "完了しました")
            if success {
                task.progress.totalUnitCount = 100
                task.progress.completedUnitCount = 100
            }
        }

        // 以降は進捗を受け取らない。新しい転送はすぐ始められるようにする。
        owner = nil
        onExpire = nil

        guard continuedTask != nil else {
            // 2 段目が動いていないなら延ばす意味が無い。
            finishNow(success: success)
            return
        }

        teardownSuccess = success
        qlog(.info, "BGTask: 転送を終えました。切断の後始末のため "
            + "\(Self.disconnectGrace) 秒だけ実行を延長します")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishNow(success: self.teardownSuccess)
        }
        pendingTeardown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disconnectGrace, execute: item)
    }

    /// 実際にタスクを閉じて実行権を手放す。
    private func finishNow(success: Bool) {
        pendingTeardown?.cancel()
        pendingTeardown = nil

        if #available(iOS 26.0, *) {
            if let task = continuedTask as? BGContinuedProcessingTask {
                task.setTaskCompleted(success: success)
                qlog(.info, "BGTask: 継続実行タスクを終了しました (success=\(success))")
            } else if let identifier = activeIdentifier {
                // ハンドラがまだ呼ばれていない = 実行前。リクエストごと取り下げる。
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                qlog(.info, "BGTask: 起動前の申請を取り下げました — \(identifier)")
            }
        }

        clearState()
        releaseAssertion()
    }

    /// 進捗が最後まで行っていたか。タスクの成否として報告する。
    private func currentProgressIsComplete() -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let task = continuedTask as? BGContinuedProcessingTask else { return false }
        let progress = task.progress
        return progress.totalUnitCount > 0
            && progress.completedUnitCount >= progress.totalUnitCount
    }

    // MARK: - 2 段目 (BGContinuedProcessingTask)

    private func submit(title: String, subtitle: String) {
        guard #available(iOS 26.0, *) else { return }

        guard let identifier = permittedIdentifier else {
            qlog(.warn, "BGTask: 使える識別子が無いため 2 段目は使いません "
                + "(バックグラウンドは約 30 秒まで)")
            return
        }

        // 申請時の環境を残す。前面でないと受理されても起動しないことがある。
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState
        let stateName: String
        switch state {
        case .active:   stateName = "active"
        case .inactive: stateName = "inactive"
        case .background: stateName = "background"
        @unknown default: stateName = "unknown"
        }
        qlog(.info, "BGTask: 申請時の状態 = \(stateName) / "
            + "バックグラウンド更新 = \(Self.refreshStatusName()) / "
            + "低電力モード = \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "オン" : "オフ")")
        #endif

        activeIdentifier = identifier

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        // 前面のユーザー操作起点なので、動かせないなら理由が欲しい。
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
            BGTaskIdentifierProbe.recordSubmit(identifier, error: nil)
            qlog(.info, "BGTask: 申請しました — \(identifier)")
            startWatchdog()
        } catch {
            activeIdentifier = nil
            BGTaskIdentifierProbe.recordSubmit(identifier, error: error.localizedDescription)
            qlog(.error, "BGTask: 申請に失敗しました — \(error.localizedDescription)")
            qlog(.warn, "BGTask: バックグラウンドは約 30 秒までに制限されます")
        }
    }

    /// OS がタスクを起動したときに呼ばれる。ここで 1 段目を手放す。
    private func attach(_ task: BGTask) {
        cancelWatchdog()

        guard #available(iOS 26.0, *) else {
            qlog(.error, "BGTask: iOS 26 未満でハンドラが呼ばれました (想定外)")
            task.setTaskCompleted(success: false)
            return
        }
        guard let continued = task as? BGContinuedProcessingTask else {
            qlog(.error, "BGTask: 渡されたタスクが BGContinuedProcessingTask では "
                + "ありませんでした — \(type(of: task))")
            task.setTaskCompleted(success: false)
            return
        }
        guard owner != nil else {
            // 起動が来る前に転送が終わっていた。すぐ畳む。
            qlog(.info, "BGTask: 転送が既に終わっていたためタスクを閉じます — "
                + continued.identifier)
            continued.setTaskCompleted(success: false)
            return
        }

        continuedTask = continued
        BGTaskIdentifierProbe.recordLaunch()
        qlog(.ok, "BGTask: ★ 継続実行タスクが起動しました。"
            + "バックグラウンドでも転送を続けます — \(continued.identifier)")

        // 申請から起動までのあいだに進んだ分を反映する。
        applyToContinuedTask()

        // ここまで来たら 1 段目は不要。長く握っていると次の機会に響く。
        releaseAssertion()

        continued.expirationHandler = { [weak self] in
            continued.setTaskCompleted(success: false)
            guard let self else { return }
            let handler = self.onExpire
            self.clearState()
            self.releaseAssertion()
            qlog(.warn, "BGTask: 継続実行タスクが打ち切られました。転送を中止します")
            handler?()
        }
    }

    /// 保持している最新の文言と進捗を、実行中のタスクへ書き込む。
    private func applyToContinuedTask() {
        guard #available(iOS 26.0, *) else { return }
        guard let owner else { return }
        guard let task = continuedTask as? BGContinuedProcessingTask else { return }

        task.updateTitle(owner.title, subtitle: lastDetail)

        if lastPercent < 0 {
            // totalUnitCount = 0 でシステム UI が不定プログレスになる。
            task.progress.totalUnitCount = 0
            task.progress.completedUnitCount = 0
        } else {
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = Int64(min(100, max(0, lastPercent)))
        }
    }

    // MARK: - 起動見張り

    /// 申請してもハンドラが来ないことがある。黙って 30 秒制限に落ちると
    /// 原因が分からないので、来なかったこと自体をログに残す。
    private func startWatchdog() {
        cancelWatchdog()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.continuedTask == nil, self.owner != nil else { return }

            BGTaskIdentifierProbe.recordLaunchTimeout()
            qlog(.error, "BGTask: 申請から \(Int(Self.launchTimeout)) 秒経っても "
                + "タスクが起動しませんでした — \(self.activeIdentifier ?? "?")")
            qlog(.warn, "BGTask: バックグラウンドは 1 段目の約 30 秒までに制限されます")
            self.dumpPendingRequests()
        }

        launchWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchTimeout, execute: item)
    }

    private func cancelWatchdog() {
        launchWatchdog?.cancel()
        launchWatchdog = nil
    }

    private func dumpPendingRequests() {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            if requests.isEmpty {
                qlog(.warn, "BGTask: 待機中の申請はありません "
                    + "(システムが受理後に取り下げた可能性)")
            } else {
                let ids = requests.map { $0.identifier }.joined(separator: ", ")
                qlog(.warn, "BGTask: 待機中の申請 — \(ids)")
            }
        }
    }

    // MARK: - 後片付け

    private func clearState() {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        teardownSuccess = false
        continuedTask = nil
        activeIdentifier = nil
        owner = nil
        onExpire = nil
        lastDetail = ""
        lastPercent = Int.min
        lastPublished = .distantPast
        cancelWatchdog()
    }

    // MARK: - 1 段目 (beginBackgroundTask)

    private func holdAssertion() {
        #if canImport(UIKit)
        guard assertionId == .invalid else { return }

        assertionId = UIApplication.shared.beginBackgroundTask(withName: "QSProbe.transfer") {
            [weak self] in
            guard let self else { return }
            self.releaseAssertion()

            // 2 段目が既に走っているなら、1 段目が切れても転送は続く。
            guard self.continuedTask == nil, self.owner != nil else { return }

            let handler = self.onExpire
            self.clearState()
            qlog(.warn, "BGTask: バックグラウンドの猶予が尽きました。転送を中止します")
            handler?()
        }
        #endif
    }

    private func releaseAssertion() {
        #if canImport(UIKit)
        guard assertionId != .invalid else { return }
        let finished = assertionId
        assertionId = .invalid
        UIApplication.shared.endBackgroundTask(finished)
        #endif
    }

    // MARK: - 補助

    #if canImport(UIKit)
    private static func refreshStatusName() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:  return "許可"
        case .denied:     return "拒否"
        case .restricted: return "制限"
        @unknown default: return "不明"
        }
    }
    #endif
}
