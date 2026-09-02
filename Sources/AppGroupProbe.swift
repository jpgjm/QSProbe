//
//  AppGroupProbe.swift
//  QSProbe
//
//  App Group が使えるかどうかを起動時に調べて診断ログへ出すだけの検証用コード。
//
//  ## なぜ要るか
//
//  共有シート (写真アプリからの「共有」など) から QSProbe へファイルを渡すには
//  Share Extension が要る。拡張とホストアプリは別サンドボックスなので、
//  ファイルの受け渡しには App Group の共有コンテナしか経路が無い。
//  AlterSend も LocalSend も同じ構成になっている。
//
//  ところが App Group は本来 Apple Developer サイトで登録する必要があり、
//  無料 Personal Team では自分で作れないとされている。
//
//  一方で LiveContainer は SideStore 経由でインストールされたときに
//  App Group が使えている。公式ドキュメントによると、署名後の entitlement は
//  こうなっている。
//
//      <key>com.apple.security.application-groups</key>
//      <array>
//          <string>group.com.rileytestut.AltStore.A1B2C3D4E5</string>
//          <string>group.com.SideStore.SideStore.A1B2C3D4E5</string>
//      </array>
//
//  自分で作ったグループではなく、**ストア自身のグループにチーム ID を付けたもの**が
//  署名時に注入されている。つまり
//
//  - グループ ID は自分で決められない可能性が高い
//  - ビルド時には確定しない (bundle ID がチーム ID 付きに書き換わるのと同じ事情)
//
//  よって「実行時に候補を総当たりして、実際にコンテナが開けたものを採用する」
//  という作りにするしかない。この Probe はその下調べ。
//
//  ## ALTAppGroups
//
//  署名ツール (Impactor) のソースを読むと、変換後のグループ ID を
//  Info.plist へ書き戻す処理がある。
//
//      bundle.set_info_plist_key(
//          "ALTAppGroups",
//          app_groups.iter().map(|s| format!("{s}.{team_id}")).collect()
//      )
//
//  つまり総当たりせずとも、ここを読めば正解が分かる可能性がある。
//  ただしこの書き戻しは署名モードが SideStore / AltStore のときだけで、
//  素の Impactor で入れた場合に付くかどうかは未確認。
//  そこで「あれば最優先で使い、無ければ従来どおり総当たり」にしてある。
//
//  ## 何を見ているか
//
//  0. `Info.plist` の `ALTAppGroups` と、ほかの `ALT` 系キーを出す。
//  1. `embedded.mobileprovision` を読んで、**実際に降ってきた** entitlement を出す。
//     プロビジョニングプロファイルはアプリバンドル内の普通のファイルなので、
//     私用 API なしで読める。CMS 署名で包まれているが、中に平文の XML plist が
//     入っているのでそこだけ切り出す。
//  2. 候補のグループ ID を総当たりして `containerURL` が nil でないものを探す。
//  3. 開けたコンテナに実際に書いて読んで消す。権限があっても書けないことがあるため。
//
//  ## この Probe を消すとき
//
//  結果が出たら `ContentView.setUpOnce()` からの呼び出しごと消してよい。
//  Share Extension を実装する段階では、ここの `resolveUsableGroup()` だけを
//  残して本番コードに移す想定。
//

import Foundation

enum AppGroupProbe {

    /// 起動時に 1 度呼ぶ。結果は診断ログに出る。
    static func dumpToLog() {
        qlog(.info, "==== App Group 調査 ====")

        let profile = readEmbeddedProfile()
        let teamId = resolveTeamId(profile: profile)

        qlog(.info, "AppGroup: bundleId = \(Bundle.main.bundleIdentifier ?? "(不明)")")
        qlog(.info, "AppGroup: チーム ID = \(teamId ?? "(取得できず)")")

        let altGroups = logInfoPlistAltKeys()
        let declared = logProfile(profile)
        let candidates = buildCandidates(
            altGroups: altGroups, declared: declared, teamId: teamId
        )

        qlog(.info, "AppGroup: 候補 \(candidates.count) 件を総当たりします")

        var usable: [String] = []
        for group in candidates {
            guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group) else {
                qlog(.info, "AppGroup:   ✗ \(group)")
                continue
            }

            qlog(.ok, "AppGroup:   ✓ \(group)")
            qlog(.info, "AppGroup:     → \(container.path)")

            if let failure = writeReadTest(in: container) {
                qlog(.warn, "AppGroup:     読み書きに失敗: \(failure)")
            } else {
                qlog(.ok, "AppGroup:     読み書きできました")
                usable.append(group)
            }
        }

        if usable.isEmpty {
            qlog(.error, "AppGroup: 使えるグループがありません。"
                + "Share Extension による共有シート対応は成立しません")
        } else {
            qlog(.ok, "AppGroup: 使えるグループ = \(usable)")

            // ALTAppGroups が当たっていれば、本番コードは総当たりを捨てて
            // Info.plist を読むだけにできる。
            if let first = altGroups.first(where: { usable.contains($0) }) {
                qlog(.ok, "AppGroup: ALTAppGroups の値が的中しました — \(first)。"
                    + "実行時の解決はこのキーを読むだけで足ります")
            } else if altGroups.isEmpty {
                qlog(.warn, "AppGroup: ALTAppGroups がありません。"
                    + "実行時の解決は候補の総当たりで行う必要があります")
            } else {
                qlog(.warn, "AppGroup: ALTAppGroups は在りますが実際に開けたものと"
                    + "一致しません。総当たりを残すこと")
            }

            qlog(.info, "AppGroup: Share Extension を作る場合、既定グループ"
                + "(group.<bundleId>.<TeamID>) は拡張側で別 ID になるため使えません。"
                + "両方の entitlement に同じ文字列を明示すること")
        }

        logSignedEntitlements(of: Bundle.main.bundleURL, label: "本体")
        logInstallArtifacts()
        logExtensions()

        // 本番コード (SharedAppGroup) が実際に何を選ぶか。
        // Probe の総当たりと食い違っていたら、そちらの優先順位がおかしい。
        if let resolved = SharedAppGroup.identifier {
            qlog(.ok, "AppGroup: 本番の解決結果 = \(resolved)")
        } else {
            qlog(.error, "AppGroup: 本番の解決に失敗しました。共有シートは機能しません")
        }

        qlog(.info, "========================")
    }

    // MARK: - Info.plist の ALT 系キー

    /// 署名ツールが書き戻した値を出し、`ALTAppGroups` の中身を返す。
    ///
    /// `ALT` で始まるキーは AltStore 系の署名ツールが注入するもので、
    /// 素の Xcode ビルドには存在しない。何が入っているかを丸ごと出しておくと、
    /// グループ ID 以外の手掛かりも拾える。
    private static func logInfoPlistAltKeys() -> [String] {
        guard let info = Bundle.main.infoDictionary else {
            qlog(.warn, "AppGroup: Info.plist を読めませんでした")
            return []
        }

        let altKeys = info.keys.filter { $0.hasPrefix("ALT") }.sorted()

        if altKeys.isEmpty {
            qlog(.info, "AppGroup: Info.plist に ALT 系のキーはありません")
        } else {
            for key in altKeys {
                qlog(.info, "AppGroup: Info.plist \(key) = \(info[key] ?? "(nil)")")
            }
        }

        guard let groups = info["ALTAppGroups"] as? [String] else {
            if info["ALTAppGroups"] != nil {
                qlog(.warn, "AppGroup: ALTAppGroups が文字列配列ではありません")
            }
            return []
        }

        qlog(.ok, "AppGroup: ALTAppGroups = \(groups)")
        return groups
    }

    // MARK: - プロビジョニングプロファイル

    /// `embedded.mobileprovision` の中の plist 部分を読む。
    ///
    /// ファイル全体は CMS (PKCS#7) 署名だが、その中に平文の XML plist が
    /// そのまま入っている。`<?xml` から `</plist>` までを切り出せば
    /// `PropertyListSerialization` で読める。
    private static func readEmbeddedProfile() -> [String: Any]? {
        guard let url = Bundle.main.url(
            forResource: "embedded", withExtension: "mobileprovision"
        ) else {
            qlog(.warn, "AppGroup: embedded.mobileprovision がありません "
                + "(未署名のビルドか、開発ビルドで実行しています)")
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            qlog(.warn, "AppGroup: embedded.mobileprovision を読めませんでした")
            return nil
        }

        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            qlog(.warn, "AppGroup: プロファイル内に plist が見つかりませんでした")
            return nil
        }

        let xml = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: xml, options: [], format: nil
        ) as? [String: Any] else {
            qlog(.warn, "AppGroup: プロファイルの plist を解析できませんでした")
            return nil
        }

        return plist
    }

    /// プロファイルの中身をログに出し、宣言されている App Group を返す。
    private static func logProfile(_ profile: [String: Any]?) -> [String] {
        guard let profile else { return [] }

        if let name = profile["Name"] as? String {
            qlog(.info, "AppGroup: プロファイル名 = \(name)")
        }
        if let expires = profile["ExpirationDate"] as? Date {
            qlog(.info, "AppGroup: 期限 = \(expires)")
        }

        guard let entitlements = profile["Entitlements"] as? [String: Any] else {
            qlog(.warn, "AppGroup: プロファイルに Entitlements がありません")
            return []
        }

        qlog(.info, "AppGroup: entitlement のキー = "
            + "\(entitlements.keys.sorted().joined(separator: ", "))")

        if let appId = entitlements["application-identifier"] as? String {
            qlog(.info, "AppGroup: application-identifier = \(appId)")
        }
        if let allow = entitlements["get-task-allow"] as? Bool {
            qlog(.info, "AppGroup: get-task-allow = \(allow)")
        }
        if let keychain = entitlements["keychain-access-groups"] as? [String] {
            qlog(.info, "AppGroup: keychain-access-groups = \(keychain.count) 件")
        }

        guard let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            qlog(.warn, "AppGroup: プロファイルに application-groups がありません。"
                + "署名時に注入されなかった可能性があります")
            return []
        }

        qlog(.ok, "AppGroup: プロファイルの application-groups = \(groups)")
        return groups
    }

    /// チーム ID を取る。
    ///
    /// `application-identifier` は `<TeamID>.<bundleId>` の形なので、最初の
    /// ドットまでが確実。プロファイルが読めないときは bundle ID の末尾から
    /// 推測する。
    private static func resolveTeamId(profile: [String: Any]?) -> String? {
        if let entitlements = profile?["Entitlements"] as? [String: Any],
           let appId = entitlements["application-identifier"] as? String,
           let dot = appId.firstIndex(of: ".") {
            return String(appId[appId.startIndex..<dot])
        }

        if let team = profile?["TeamIdentifier"] as? [String], let first = team.first {
            return first
        }

        // 推測。com.anony.qsprobe.48A5LFNW96 → 48A5LFNW96
        if let bundleId = Bundle.main.bundleIdentifier,
           let last = bundleId.split(separator: ".").last,
           last.count == 10,
           last.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return String(last)
        }

        return nil
    }

    // MARK: - 候補

    /// 試すグループ ID を優先順に並べる。
    private static func buildCandidates(
        altGroups: [String], declared: [String], teamId: String?
    ) -> [String] {
        var candidates: [String] = []

        func add(_ group: String) {
            guard !candidates.contains(group) else { return }
            candidates.append(group)
        }

        // 0. 署名ツールが Info.plist に書き戻した値。当たれば総当たりは不要になる。
        altGroups.forEach(add)

        // 1. プロファイルに実際に書いてあるもの。これも確実。
        declared.forEach(add)

        // 2. project.yml で自分が宣言したもの。素のままと、チーム ID 付き。
        let base = "com.anony.qsprobe"
        add("group.\(base)")
        if let teamId { add("group.\(base).\(teamId)") }

        // 3. ストアのグループ。LiveContainer が実際に使っているのはこれ。
        add("group.com.SideStore.SideStore")
        if let teamId {
            add("group.com.SideStore.SideStore.\(teamId)")
            add("group.com.rileytestut.AltStore.\(teamId)")
        }
        add("group.com.rileytestut.AltStore")

        return candidates
    }

    // MARK: - 読み書きの確認

    /// コンテナが開けても実際に書けるとは限らないので、往復させて確かめる。
    /// 成功なら nil、失敗ならその理由を返す。
    private static func writeReadTest(in container: URL) -> String? {
        let file = container.appendingPathComponent("qsprobe-appgroup-test.txt")
        let payload = "QSProbe \(Date().timeIntervalSince1970)"

        do {
            try payload.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "書き込み — \(error.localizedDescription)"
        }

        defer { try? FileManager.default.removeItem(at: file) }

        do {
            let readBack = try String(contentsOf: file, encoding: .utf8)
            guard readBack == payload else { return "読み戻した内容が違います" }
        } catch {
            return "読み込み — \(error.localizedDescription)"
        }

        return nil
    }

    // MARK: - 署名に焼かれた entitlements

    /// 実行ファイルのコード署名に**実際に焼き込まれた** entitlements を出す。
    ///
    /// プロビジョニングプロファイルは「何を要求してよいか」の許可証で、
    /// 署名時に実際に何が焼かれたかとは別物。両者が食い違うと AMFI が
    /// プロセスの起動を拒み、ログも残らない。拡張が黙って起動しないときは
    /// ここを見るしかない。
    private static func logSignedEntitlements(of bundle: URL, label: String) {
        guard let entitlements = MachOEntitlements.read(bundle: bundle) else {
            qlog(.error, "AppGroup: \(label) 署名の entitlements を読めませんでした。"
                + "署名されていないか、形式が想定と違います")
            return
        }

        qlog(.info, "AppGroup: \(label) 署名の entitlements = "
            + "\(entitlements.keys.sorted().joined(separator: ", "))")

        if let appId = entitlements["application-identifier"] as? String {
            qlog(.info, "AppGroup: \(label) 署名 application-identifier = \(appId)")
        } else {
            qlog(.error, "AppGroup: \(label) 署名に application-identifier がありません")
        }

        if let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            qlog(.ok, "AppGroup: \(label) 署名 application-groups = \(groups)")
        } else {
            qlog(.warn, "AppGroup: \(label) 署名に application-groups がありません")
        }

        logCodeDirectory(of: bundle, label: label)
        logExecutableFile(of: bundle, label: label)
        logSignatureBlobs(of: bundle, label: label)
    }

    /// コード署名に入っている blob の一覧を出す。
    ///
    /// 同じ .app でも署名ツールによって実行ファイルの大きさが 10 万バイト
    /// 違うことが実測で分かった。署名ブロブの構成そのものが違うということ。
    /// 何が入って何が欠けているかを直接数える。
    ///
    /// iOS 15 以降は DER 形式の entitlements を見る箇所があり、XML 版しか
    /// 無い署名は弾かれることがある。App Extension は本体より判定が厳しい
    /// 場面があるので、ここが欠けていれば有力な候補になる。
    private static func logSignatureBlobs(of bundle: URL, label: String) {
        guard let result = MachOEntitlements.signatureBlobs(bundle: bundle) else {
            qlog(.warn, "AppGroup: \(label) 署名 blob を読めませんでした")
            return
        }

        qlog(.info, "AppGroup: \(label) 署名全体 = \(result.total) bytes / "
            + "blob \(result.blobs.count) 個")

        for blob in result.blobs {
            let name = MachOEntitlements.blobName(type: blob.type, magic: blob.magic)
            qlog(.info, "AppGroup: \(label)   [\(String(blob.type, radix: 16))] "
                + "\(name) \(blob.length) bytes")
        }

        let hasDER = result.blobs.contains { $0.magic == 0xFADE_7172 }
        if !hasDER {
            qlog(.warn, "AppGroup: \(label) DER 形式の entitlements がありません")
        }
    }

    /// 実行ファイルの大きさとパーミッションを出す。
    ///
    /// SideStore はアプリ内で IPA を組み立て、AFC で押し込んでから
    /// installation_proxy に投げる。minimuxer 側の実装はこうなっている。
    ///
    ///     let mut client_opts = Dictionary::new();
    ///     client_opts.insert("CFBundleIdentifier".into(), bundle_id.into());
    ///     inst_client.install("./PublicStaging/<bundleId>/app.ipa", opts)
    ///
    /// つまり **zip を展開するのは installd** で、展開後のパーミッションは
    /// zip の外部属性から決まる。ここで拡張の実行ビットが落ちていれば、
    /// ファイルは存在し署名も正しいのに exec できない。
    /// 「共有シートに出るのにプロセスが 1 命令も動かない」という症状と合う。
    ///
    /// ホスト本体と拡張を並べて出すので、片方だけ 0o644 なら決まり。
    private static func logExecutableFile(of bundle: URL, label: String) {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let name = info["CFBundleExecutable"] as? String else {
            qlog(.warn, "AppGroup: \(label) CFBundleExecutable がありません")
            return
        }

        let executable = bundle.appendingPathComponent(name)
        let manager = FileManager.default

        guard let attributes = try? manager.attributesOfItem(atPath: executable.path) else {
            qlog(.error, "AppGroup: \(label) 実行ファイルの属性を読めませんでした — \(name)")
            return
        }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let modeText = mode >= 0 ? "0o" + String(mode, radix: 8) : "(不明)"

        qlog(.info, "AppGroup: \(label) 実行ファイル = \(name) / \(size) bytes / \(modeText)")

        // 所有者の実行ビット (0o100) が立っているか。
        if mode >= 0, mode & 0o100 == 0 {
            qlog(.error, "AppGroup: \(label) 実行ビットがありません。"
                + "このバイナリは起動できません")
        }

        // isExecutableFile は動いている側でも false を返した (サンドボックス下では
        // access(X_OK) が通らない)。判定に使えないので見ない。
    }

    /// CodeDirectory の素性を出す。
    ///
    /// `identifier` は署名時に付けられる識別子で、通常は bundle ID と同じに
    /// なる。再署名ツールが Info.plist の bundle ID を書き換えたのに署名
    /// 識別子を元のままにすると、ここが食い違う。iOS はその状態のバンドルを
    /// 拒むので、拡張が黙って起動しない原因になりうる。
    ///
    /// entitlements が両ツールで完全一致していたため、次に疑うのはここ。
    private static func logCodeDirectory(of bundle: URL, label: String) {
        guard let directory = MachOEntitlements.codeDirectory(bundle: bundle) else {
            qlog(.warn, "AppGroup: \(label) CodeDirectory を読めませんでした")
            return
        }

        qlog(.info, "AppGroup: \(label) 署名 identifier = \(directory.identifier)")
        qlog(.info, "AppGroup: \(label) 署名 teamId = \(directory.teamId ?? "(なし)")")
        qlog(.info, "AppGroup: \(label) 署名 flags = 0x"
            + String(directory.flags, radix: 16))

        // CodeDirectory の細部。iloader と SideStore で署名全体の大きさが
        // 大きく違っていたので、ハッシュ種別・ページ長・スロット数まで見る。
        qlog(.info, "AppGroup: \(label) 署名 CD version = 0x"
            + String(directory.version, radix: 16)
            + " / \(directory.hashName) (\(directory.hashSize)B)"
            + " / page \(directory.pageSize)B")
        qlog(.info, "AppGroup: \(label) 署名 スロット = "
            + "special \(directory.specialSlots) / code \(directory.codeSlots)")

        if let execSegFlags = directory.execSegFlags {
            // 0x1 = CS_EXECSEG_MAIN_BINARY。主実行ファイルに立つ印。
            qlog(.info, "AppGroup: \(label) 署名 execSegFlags = 0x"
                + String(execSegFlags, radix: 16)
                + (execSegFlags & 0x1 != 0 ? " (MAIN_BINARY)" : ""))
        } else {
            qlog(.info, "AppGroup: \(label) 署名 execSegFlags なし "
                + "(CD version が 0x20400 未満)")
        }

        // special スロットは Info.plist(-1) / Requirements(-2) /
        // CodeResources(-3) / Entitlements(-5) / DER Entitlements(-7) を封じる。
        // 7 未満だと DER entitlements が CodeDirectory に封印されていない。
        if directory.specialSlots < 7 {
            qlog(.warn, "AppGroup: \(label) special スロットが "
                + "\(directory.specialSlots) 個しかありません。"
                + "DER entitlements が封印されていない可能性があります")
        }

        let bundleId = Bundle(url: bundle)?.infoDictionary?["CFBundleIdentifier"] as? String
        if let bundleId {
            if directory.identifier == bundleId {
                qlog(.ok, "AppGroup: \(label) 署名 identifier は bundleId と一致しています")
            } else {
                qlog(.error, "AppGroup: \(label) 署名 identifier が bundleId と"
                    + "食い違っています (signature=\(directory.identifier) / "
                    + "bundle=\(bundleId))")
            }
        }

        // 0x2 = adhoc。ad-hoc 署名のまま残っていると実機では起動できない。
        if directory.flags & 0x2 != 0 {
            qlog(.error, "AppGroup: \(label) ad-hoc 署名のままです。"
                + "再署名ツールが署名し直していません")
        }
    }

    // MARK: - インストール経路の痕跡

    /// `SC_Info` とバンドル直下の構成を出す。
    ///
    /// バンドルの中身 (署名・entitlements・プロファイル・Info.plist) は
    /// 署名ツールを変えても完全一致することが分かった。それでも片方でだけ
    /// 拡張が起動しないので、残る違いは**インストールのされ方**にある。
    ///
    /// `SC_Info/Manifest.plist` の `SinfReplicationPaths` は、installd が
    /// どのファイルに sinf (署名情報) を配るかの一覧。ここから `PlugIns/` が
    /// 落ちていると、拡張だけ sinf を受け取れずに起動できない、という筋が
    /// 立つ。SideStore のソースには実際に
    ///
    ///     sinfReplicationPaths.filter { !$0.starts(with: "PlugIns/") }
    ///
    /// という処理がある (拡張を削除したときの後始末用)。これが意図せず
    /// 効いていないかを確かめる。
    private static func logInstallArtifacts() {
        let bundle = Bundle.main.bundleURL
        let manager = FileManager.default

        // バンドル直下に何があるか。SC_Info の有無もここで分かる。
        if let entries = try? manager.contentsOfDirectory(atPath: bundle.path) {
            let interesting = entries
                .filter { $0.hasPrefix("SC_Info") || $0.hasPrefix("_") || $0.hasPrefix("embedded")
                    || $0 == "PlugIns" }
                .sorted()
            qlog(.info, "AppGroup: バンドル直下の要素 = "
                + (interesting.isEmpty ? "(該当なし)" : interesting.joined(separator: ", ")))
        }

        let scInfo = bundle.appendingPathComponent("SC_Info", isDirectory: true)
        guard manager.fileExists(atPath: scInfo.path) else {
            qlog(.info, "AppGroup: SC_Info がありません "
                + "(sinf 配布の仕組みを使っていないインストール経路)")
            return
        }

        if let entries = try? manager.contentsOfDirectory(atPath: scInfo.path) {
            qlog(.info, "AppGroup: SC_Info = \(entries.sorted().joined(separator: ", "))")
        }

        let manifest = scInfo.appendingPathComponent("Manifest.plist")
        guard let data = try? Data(contentsOf: manifest),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            qlog(.warn, "AppGroup: Manifest.plist を読めませんでした")
            return
        }

        qlog(.info, "AppGroup: Manifest のキー = "
            + plist.keys.sorted().joined(separator: ", "))

        guard let paths = plist["SinfReplicationPaths"] as? [String] else {
            qlog(.warn, "AppGroup: SinfReplicationPaths がありません")
            return
        }

        let plugInPaths = paths.filter { $0.hasPrefix("PlugIns/") }
        qlog(.info, "AppGroup: SinfReplicationPaths = \(paths.count) 件 "
            + "(うち PlugIns/ が \(plugInPaths.count) 件)")

        if plugInPaths.isEmpty {
            qlog(.error, "AppGroup: SinfReplicationPaths に PlugIns/ がありません。"
                + "拡張が sinf を受け取れていない可能性があります")
        } else {
            for path in plugInPaths.sorted() {
                qlog(.ok, "AppGroup:   \(path)")
            }
        }
    }

    // MARK: - App Extension の点検

    /// 同梱されている App Extension を調べる。
    ///
    /// 拡張が「共有シートに出るのに何もしない」とき、原因は大きく 2 つある。
    ///
    /// 1. 主クラスが解決できず、そもそも起動していない
    /// 2. 起動はしたが App Group が無く、ファイルを置く先が無い
    ///
    /// 2 は拡張の `embedded.mobileprovision` を見れば分かる。拡張は
    /// ホストの `PlugIns/` の中にあるので、ホストから普通に読める。
    /// ホストと同じグループが載っていなければ、ad-hoc 署名の対応付けか
    /// 署名ツール側の割り当てが失敗している。
    ///
    /// 1 のほうはホストからは確かめようがない。拡張が動けば
    /// 共有コンテナの `extension.log` に足跡が残るので、そちらで判断する。
    private static func logExtensions() {
        let plugIns = Bundle.main.bundleURL.appendingPathComponent("PlugIns", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: plugIns, includingPropertiesForKeys: nil
        ) else {
            qlog(.warn, "AppGroup: PlugIns がありません。App Extension が同梱されていません")
            return
        }

        let extensions = entries.filter { $0.pathExtension == "appex" }
        guard !extensions.isEmpty else {
            qlog(.warn, "AppGroup: PlugIns に .appex がありません")
            return
        }

        for appex in extensions {
            qlog(.info, "AppGroup: 拡張 \(appex.lastPathComponent)")

            let info = Bundle(url: appex)?.infoDictionary
            if let bundleId = info?["CFBundleIdentifier"] as? String {
                qlog(.info, "AppGroup:   bundleId = \(bundleId)")
            }
            if let version = info?["CFBundleShortVersionString"] as? String,
               let build = info?["CFBundleVersion"] as? String {
                // ホストと食い違うと iOS が拡張の起動を拒む。
                qlog(.info, "AppGroup:   バージョン = \(version) (\(build))")
            }
            if let packageType = info?["CFBundlePackageType"] as? String {
                // App Extension は XPC! でなければならない。
                qlog(.info, "AppGroup:   PackageType = \(packageType)")
            }
            if let extensionInfo = info?["NSExtension"] as? [String: Any] {
                let principal = extensionInfo["NSExtensionPrincipalClass"] as? String
                qlog(.info, "AppGroup:   主クラス = \(principal ?? "(未設定)")")
                let point = extensionInfo["NSExtensionPointIdentifier"] as? String
                qlog(.info, "AppGroup:   拡張ポイント = \(point ?? "(未設定)")")
            } else {
                qlog(.error, "AppGroup:   NSExtension がありません")
            }

            // 署名ツールが拡張にも何か書き込んでいるか。
            let altKeys = (info?.keys.filter { $0.hasPrefix("ALT") } ?? []).sorted()
            qlog(.info, "AppGroup:   ALT 系キー = "
                + (altKeys.isEmpty ? "なし" : altKeys.joined(separator: ", ")))

            // 署名の有無。_CodeSignature が無ければ署名されていない。
            // 未署名の App Extension は iOS が起動を拒む。
            let signature = appex.appendingPathComponent("_CodeSignature/CodeResources")
            let signed = FileManager.default.fileExists(atPath: signature.path)
            if signed {
                qlog(.ok, "AppGroup:   _CodeSignature = あり")
            } else {
                qlog(.error, "AppGroup:   _CodeSignature がありません。"
                    + "署名ツールが拡張を署名していません")
            }

            let profileName = SharedAppGroup.profileName(in: appex)
            qlog(.info, "AppGroup:   プロファイル = \(profileName ?? "(なし)")")

            // application-identifier と bundleId の突き合わせ。
            //
            // iOS は「署名の application-identifier == <TeamID>.<CFBundleIdentifier>」
            // を要求する。食い違うバンドルは起動を拒まれる。
            // ホストのプロファイルを拡張に使い回すと、application-identifier が
            // ホストのままなので必ずここで落ちる (SideStore の
            // 「Use Main Profile」を選んだときに起きる)。
            let appId = SharedAppGroup.profileApplicationIdentifier(in: appex)
            let bundleId = (Bundle(url: appex)?.infoDictionary?["CFBundleIdentifier"] as? String)
            if let appId, let bundleId {
                qlog(.info, "AppGroup:   application-identifier = \(appId)")
                // <TeamID>. を落として比べる。
                let expected = appId.drop { $0 != "." }.dropFirst()
                if expected == bundleId {
                    qlog(.ok, "AppGroup:   bundleId と一致しています")
                } else {
                    qlog(.error, "AppGroup:   bundleId と食い違っています。"
                        + "この拡張は iOS に起動を拒まれます "
                        + "(profile=\(expected) / bundle=\(bundleId))")
                    qlog(.warn, "AppGroup:   → 署名時に拡張ごとの App ID を"
                        + "登録し直してください")
                }
            }

            if let entries = try? FileManager.default.contentsOfDirectory(atPath: appex.path) {
                qlog(.info, "AppGroup:   中身 = \(entries.sorted().joined(separator: ", "))")
            }

            logSignedEntitlements(of: appex, label: "  拡張")

            let groups = SharedAppGroup.profileAppGroups(in: appex)
            if groups.isEmpty {
                qlog(.error, "AppGroup:   application-groups がありません。"
                    + "拡張はファイルを渡せません")
            } else {
                qlog(.ok, "AppGroup:   application-groups = \(groups)")
            }
        }
    }

}
