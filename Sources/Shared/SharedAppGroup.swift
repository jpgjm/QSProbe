//
//  SharedAppGroup.swift
//  QSProbe
//
//  ホストアプリと Share Extension が同じ共有コンテナを指すための解決処理。
//
//  ## なぜ実行時に解決するのか
//
//  `project.yml` には `group.com.anony.qsprobe` と書いてあるが、実機で
//  実際に存在するのは `group.com.anony.qsprobe.48A5LFNW96` になる。
//  署名ツールがチーム ID を後ろに足すため。bundle ID が
//  `com.anony.qsprobe` → `com.anony.qsprobe.48A5LFNW96` になるのと同じ。
//
//  Impactor のソースだとこの一行:
//
//      let mut group_name = format!("{group}.{team_id}");
//
//  ビルド時にはチーム ID が確定しないので、直書きできない。
//
//  ## 解決の順番
//
//  実機で 2 通りの署名ツールを比べた結果がこう分かれた。
//
//  | 手掛かり | Impactor | SideStore |
//  |---|---|---|
//  | `Info.plist` の `ALTAppGroups` | **無い** | 有る |
//  | `embedded.mobileprovision` の `application-groups` | 有る (2 件) | 有る (1 件) |
//
//  `ALTAppGroups` は AltStore 系の署名ツールが書き戻すキーで、素の Impactor
//  では付かない。逆にプロファイルはどちらでも読める。よって
//
//    1. `ALTAppGroups`            … SideStore で入れたとき一発で当たる
//    2. プロファイルの記載        … Impactor で入れたときはここで当たる
//    3. 決め打ちの候補            … 保険
//
//  の順に試し、`containerURL` が返ってきたものを採用する。
//
//  ## 既定グループを使わない理由
//
//  Impactor は宣言したグループとは別に `group.<bundleId>.<TeamID>` を
//  自動で足す。しかし拡張の bundle ID はホストと違うので、拡張側では
//  別の ID になってしまい共有できない。しかも SideStore はこの自動追加を
//  行わない。したがって**両方の entitlement に明示した 1 個**だけを使う。
//
//  ## 寿命
//
//  再インストールのたびに共有コンテナの UUID は変わる (実測で確認済み)。
//  つまり中身は消える。共有シートから渡されたファイルはここに置きっぱなしに
//  せず、受け取ったら即座にアプリ側の領域へ移すこと。
//

import Foundation

enum SharedAppGroup {

    /// `project.yml` に書いた素のグループ ID。実機ではこれにチーム ID が付く。
    static let declaredIdentifier = "group.com.anony.qsprobe"

    /// 解決結果。1 プロセスに 1 回だけ調べる。
    private static var cached: String??

    /// 使えるグループ ID。使えなければ nil。
    static var identifier: String? {
        if let cached { return cached }
        let resolved = resolve()
        cached = resolved
        return resolved
    }

    /// 共有コンテナの URL。
    static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 共有シートから渡されたファイルを置く場所。
    static var inboxURL: URL? {
        guard let containerURL else { return nil }
        let dir = containerURL.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 拡張側のログの置き場。
    ///
    /// App Extension には診断ログ画面が無く、Mac が無いと Console でも
    /// 追えない。そこで共有コンテナにテキストで書き、ホスト側が取り込み時に
    /// 読み上げて自前の診断ログへ流す。拡張が黙って失敗する事故を防ぐため。
    static var extensionLogURL: URL? {
        containerURL?.appendingPathComponent("extension.log")
    }

    /// 拡張から 1 行書く。失敗しても何もしない (ログのために落ちては本末転倒)。
    static func appendExtensionLog(_ message: String) {
        guard let url = extensionLogURL else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 溜まっている拡張ログを読み出して消す。ホスト側から呼ぶ。
    ///
    /// 書き込み側が別のグループを選んでいる可能性があるので、
    /// 読む側はグループを指定できるようにしてある。
    static func drainExtensionLog(in group: String) -> [String] {
        guard let url = extensionLogURL(for: group),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        try? FileManager.default.removeItem(at: url)
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - 解決

    private static func resolve() -> String? {
        for candidate in candidates() {
            guard FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil else {
                continue
            }
            return candidate
        }
        return nil
    }

    /// 優先順に候補を並べる。重複は落とす。
    ///
    /// ## ホストと拡張で別々の ID を掴む事故
    ///
    /// 署名ツールはバンドルごとに「そのバンドル専用のグループ」を足す。
    /// 実測 (Impactor) だとこうなっていた。
    ///
    ///   ホスト : group.com.anony.qsprobe.48A5LFNW96.48A5LFNW96   ← ホスト専用
    ///            group.com.anony.qsprobe.48A5LFNW96              ← 宣言した共通
    ///   拡張   : group.com.anony.qsprobe.48A5LFNW96.share.48A5LFNW96  ← 拡張専用
    ///            group.com.anony.qsprobe.48A5LFNW96              ← 宣言した共通
    ///
    /// 各々が自分のリストの先頭を採ると、ホストは 1 番目、拡張は 2 番目を
    /// 掴んで別のコンテナになる。拡張は「渡しました」と言うのに、ホストには
    /// 何も見えない。実際にこの症状が出た。
    ///
    /// ## 直し方
    ///
    /// **ホストと同梱されている全拡張の共通集合**を最優先にする。
    /// 共有コンテナは定義上、全員から見えるものでなければならない。
    /// ホストから呼んでも拡張から呼んでも同じ集合を計算するので、
    /// 必ず同じ ID に落ち着く。
    private static func candidates() -> [String] {
        var out: [String] = []

        func add(_ group: String) {
            guard group.hasPrefix("group."), !out.contains(group) else { return }
            out.append(group)
        }

        // 1. ホストと全拡張の共通集合。これが本命。
        commonGroups().forEach(add)

        // 2. 署名ツールが Info.plist に書き戻した値 (SideStore 系)
        if let alt = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            alt.forEach(add)
        }

        // 3. 自分のプロファイルに載っているもの。
        let own = profileAppGroups(in: Bundle.main.bundleURL)
        own.filter { $0.hasPrefix(declaredIdentifier) }.forEach(add)
        own.forEach(add)

        // 4. 保険。チーム ID は bundle ID の末尾から推測する。
        add(declaredIdentifier)
        if let team = teamIdFromBundleId() {
            add("\(declaredIdentifier).\(team)")
        }

        return out
    }

    /// ホストと同梱されている全 App Extension に共通するグループ。
    ///
    /// 拡張が 1 つも無ければホストのものをそのまま返す。
    private static func commonGroups() -> [String] {
        let host = hostBundleURL
        var common = profileAppGroups(in: host)
        guard !common.isEmpty else { return [] }

        let plugIns = host.appendingPathComponent("PlugIns", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: plugIns, includingPropertiesForKeys: nil
        ) else {
            return common
        }

        for appex in entries where appex.pathExtension == "appex" {
            let groups = profileAppGroups(in: appex)
            // プロファイルを読めない拡張は判断材料にしない。
            // 読めないだけで共通集合を空にすると、全体が壊れる。
            guard !groups.isEmpty else { continue }
            common = common.filter { groups.contains($0) }
        }

        // 宣言した ID 由来のものを先に。
        return common.filter { $0.hasPrefix(declaredIdentifier) }
            + common.filter { !$0.hasPrefix(declaredIdentifier) }
    }

    /// ホストアプリのバンドル。
    ///
    /// ホストから呼ばれたときは `Bundle.main` そのもの。
    /// 拡張から呼ばれたときは `App.app/PlugIns/X.appex` にいるので 2 つ上。
    static var hostBundleURL: URL {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return url }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// アクセスできるグループを全部返す。
    ///
    /// 取り込み側 (ホスト) はこれを使って**全部のコンテナを走査**する。
    /// 書き込み側が別の ID を選んでいても取りこぼさないための保険。
    /// 読むだけなので、多めに見に行っても害はない。
    static var allUsableIdentifiers: [String] {
        candidates().filter {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }

    /// 指定したグループの受信箱。
    static func inboxURL(for group: String) -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let dir = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 指定したグループの拡張ログ。
    static func extensionLogURL(for group: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("extension.log")
    }

    /// 指定したバンドルの `embedded.mobileprovision` から
    /// `application-groups` を読む。
    ///
    /// プロファイルは CMS 署名で包まれているが、中に平文の XML plist が
    /// そのまま入っているので、その範囲だけ切り出せば解析できる。
    static func profileAppGroups(in bundle: URL) -> [String] {
        guard let plist = profilePlist(in: bundle),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return []
        }

        return groups
    }

    /// プロファイル名。どの署名ツールがいつ作ったものかの手掛かりになる。
    static func profileName(in bundle: URL) -> String? {
        profilePlist(in: bundle)?["Name"] as? String
    }

    /// `embedded.mobileprovision` の plist 部分を読む。
    private static func profilePlist(in bundle: URL) -> [String: Any]? {
        let url = bundle.appendingPathComponent("embedded.mobileprovision")

        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            return nil
        }

        return try? PropertyListSerialization.propertyList(
            from: data[start.lowerBound..<end.upperBound], options: [], format: nil
        ) as? [String: Any]
    }

    /// プロファイルの `application-identifier`。
    /// `<TeamID>.<bundleId>` の形で、バンドルの CFBundleIdentifier と
    /// 一致していないと iOS はそのバンドルを起動しない。
    static func profileApplicationIdentifier(in bundle: URL) -> String? {
        guard let plist = profilePlist(in: bundle),
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return nil
        }
        return entitlements["application-identifier"] as? String
    }

    /// bundle ID の末尾からチーム ID を推測する。
    /// 署名ツールが `com.anony.qsprobe` → `com.anony.qsprobe.48A5LFNW96` と
    /// 書き換えるので、末尾 10 桁の英数字がそれに当たる。
    private static func teamIdFromBundleId() -> String? {
        guard let bundleId = Bundle.main.bundleIdentifier,
              let last = bundleId.split(separator: ".").last,
              last.count == 10,
              last.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
            return nil
        }
        return String(last)
    }
}
