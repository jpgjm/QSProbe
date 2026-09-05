//
//  BGTaskIdentifierProbe.swift
//  QSProbe
//
//  v1.16.0 で追加。**検証専用**。転送の動作には既定では一切影響しない。
//
//  ## 何を確かめるためのものか
//
//  「SideStore が bundle ID にチーム ID を足すのに
//  `BGTaskSchedulerPermittedIdentifiers` の中身は書き換えないので、
//  素の識別子では BGTask のハンドラが黙って呼ばれなくなる」
//
//  という主張を、**同じビルド・同じ署名・同じ端末**で A/B して裏を取る。
//
//  BackgroundTransferTask.swift の冒頭に rev1〜rev3 の表があるが、あれは
//  別々のビルドをまたいだ比較なので、報告の根拠としてはやや弱い。ここでは
//  1 つのビルドの中でモードだけを切り替えて、同じ条件下で差が出ることを示す。
//
//  ## 3 つのモード
//
//  | モード | 使う識別子 | plist に記載 | 実行時 bundle ID 配下 | 期待 |
//  |---|---|---|---|---|
//  | `auto` | `<実行時bundleId>.transfer` | あり | **はい** | 起動する (陽性対照) |
//  | `plain` | `com.anony.qsprobe.transfer` | あり | いいえ (SideStore 版) | register は通るが**起動しない** |
//  | `unlisted` | `com.anony.qsprobe-unlisted.transfer` | **なし** | — | `register()` が **false** |
//
//  `plain` が主張の対象。`auto` が陽性対照で、「単に BGTask が走らなかった
//  だけ」と区別するために要る。`unlisted` は「許可リストに無い」と
//  「許可リストにはあるが bundle ID 配下でない」が**別の失敗の仕方**を
//  することの確認で、これが取れると 2 つの症状を混同していないと言える。
//
//  ## Info.plist は触らない
//
//  3 モードとも既存の `BGTaskSchedulerPermittedIdentifiers` のままで試せる。
//  `unlisted` は「載っていない識別子」なので、載せてはいけない。
//
//  よって**再インストールも端末再起動も不要**。`installd` がキャッシュする
//  のは Info.plist の許可リストであって、アプリがどれを register するかでは
//  ないため。モードを変えたら再起動 (アプリの) だけでよい。
//
//  ## モードの反映が「次回起動から」な理由
//
//  `BGTaskScheduler.register()` は起動完了までに呼ぶ必要があり、
//  QSProbe では `QSProbeApp.init()` から 1 度だけ呼んでいる。画面から
//  切り替えても、その場では登録し直せない。UserDefaults に置いて、
//  次の起動で読む。
//

import Foundation

/// 検証で使う識別子の選び方。
enum BGTaskIdentifierMode: String, CaseIterable, Identifiable {

    /// 通常動作。実行時 bundle ID 配下を優先し、駄目なら素の系列に落ちる。
    case auto

    /// 素の bundle ID 配下だけを使う。SideStore 版では実行時 bundle ID の
    /// 配下ではなくなるので、これが主張の検証対象になる。
    case plain

    /// Info.plist に載せていない識別子を使う。`register()` が false を
    /// 返すことの確認用。
    case unlisted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:     return "通常 (実行時 bundle ID 配下)"
        case .plain:    return "素の識別子に固定"
        case .unlisted: return "許可リスト外の識別子"
        }
    }

    var expectation: String {
        switch self {
        case .auto:
            return "陽性対照。register() が通り、申請後 1 秒未満でタスクが起動するはず。"
        case .plain:
            return "検証対象。register() は通り submit も成功するのに、"
                + "タスクだけが起動しないはず (見張りが 2 秒で警告を出す)。"
        case .unlisted:
            return "register() が false を返すはず。ここで false にならなければ、"
                + "許可リストの照合が効いていないことになる。"
        }
    }
}

/// 検証の状態置き場。
///
/// `ObservableObject` にしていないのは、`DiagnosticsView` が
/// `DiagnosticLog` を監視していて、ここに記録する出来事はすべて同時に
/// `qlog()` へも流れるため。ログが 1 行増えれば画面全体が引き直され、
/// この値も読み直される。Combine を足す必要が無い。
enum BGTaskIdentifierProbe {

    /// UserDefaults のキー。画面が書き、起動時に読む。
    static let defaultsKey = "QSProbeBGTaskIdentifierMode"

    /// Info.plist に**載せていない**識別子。`unlisted` モードで使う。
    ///
    /// `com.anony.qsprobe` の配下にしていないのは、将来 plist に
    /// ワイルドカードや前方一致が導入されたときに巻き込まれないため。
    static let unlistedIdentifier = "com.anony.qsprobe-unlisted.transfer"

    // MARK: - 次回起動に適用される設定

    /// 画面で選ばれているモード。次の起動から効く。
    static var pendingMode: BGTaskIdentifierMode {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return BGTaskIdentifierMode(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    // MARK: - この起動で実際に使われた値 (読み取り専用)

    /// この起動で凍結されたモード。`register()` の先頭で 1 度だけ入る。
    private(set) static var activeMode: BGTaskIdentifierMode = .auto

    /// `register()` を試した識別子と、その戻り値。試した順。
    ///
    /// タプルの配列にしないのは、Swift がタプルの要素への KeyPath を
    /// 作れず `ForEach(_:id:)` に渡せないため。
    struct RegisterOutcome: Identifiable {
        let identifier: String
        let accepted: Bool
        var id: String { identifier }
    }

    private(set) static var registerOutcomes: [RegisterOutcome] = []

    /// 採用された識別子。nil なら 2 段目は使えない。
    private(set) static var adopted: String?

    /// 直近の `submit()` の結果。
    private(set) static var lastSubmit: String?

    /// 直近の申請でハンドラが来たか。nil はまだ申請していない。
    private(set) static var lastLaunchFired: Bool?

    /// 申請からハンドラ到達までの実測 (ミリ秒)。
    private(set) static var lastLaunchLatencyMs: Int?

    /// 申請した時刻。所要時間の計算に使う。
    private static var submittedAt: Date?

    // MARK: - 記録

    static func freeze(mode: BGTaskIdentifierMode) {
        activeMode = mode
        registerOutcomes = []
        adopted = nil
        lastSubmit = nil
        lastLaunchFired = nil
        lastLaunchLatencyMs = nil
        submittedAt = nil
    }

    static func recordRegister(_ identifier: String, accepted: Bool) {
        registerOutcomes.append(RegisterOutcome(identifier: identifier, accepted: accepted))
        if accepted { adopted = identifier }
    }

    static func recordSubmit(_ identifier: String, error: String?) {
        submittedAt = Date()
        lastLaunchFired = nil
        lastLaunchLatencyMs = nil
        lastSubmit = error.map { "失敗 — \($0)" } ?? "成功 — \(identifier)"
    }

    static func recordLaunch() {
        lastLaunchFired = true
        if let submittedAt {
            lastLaunchLatencyMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
        }
    }

    static func recordLaunchTimeout() {
        // 見張りが鳴った時点では「まだ来ていない」。後から来る可能性は
        // 残るが、来たときに recordLaunch() が上書きするので問題ない。
        lastLaunchFired = false
    }

    /// この起動の設定をログへ吐く。`register()` から呼ぶ。
    static func dumpToLog() {
        guard activeMode != .auto else { return }
        qlog(.warn, "BGTask検証: モード = \(activeMode.label) "
            + "(通常動作ではありません。診断画面で戻せます)")
        qlog(.info, "BGTask検証: 期待される結果 — \(activeMode.expectation)")
    }
}
