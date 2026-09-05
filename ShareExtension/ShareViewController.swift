//
//  ShareViewController.swift
//  QSProbeShare
//
//  共有シートから渡された添付物を共有コンテナへ置き、ホストアプリを起こす。
//
//  ## 拡張は転送しない
//
//  App Extension はメモリ上限が厳しく (実測で 120 MB 前後)、長時間の
//  ネットワーク処理には耐えない。AlterSend も LocalSend も同じ判断で、
//  拡張は「ファイルを渡すだけの中継役」に徹している。ここも同じ。
//
//  ## 流れ
//
//  1. `NSExtensionContext.inputItems` → `NSItemProvider` を走査する
//  2. `loadFileRepresentation` で実体を取り出し、共有コンテナへコピーする
//  3. マニフェスト (`payload.json`) を書く
//  4. カスタム URL スキームでホストアプリを起こす
//  5. `completeRequest` でシートを閉じる
//
//  マニフェストは実体を全部コピーし終えてから書く。ホスト側は
//  `payload.json` があるフォルダだけを取り込むので、これだけで
//  「書き込み途中のものを読んでしまう」競合を防げる。
//
//  ## 画面を出す
//
//  最初は透明なまま黙って閉じる作りにしたが、実機で「共有シートには出るのに
//  何も起きない」状態になったとき、原因が全く追えなかった。
//  拡張には診断ログ画面が無く、Mac が無ければ Console も見られない。
//
//  そこで結果を画面に出す。これで最低限、
//
//  - 何も出ない        → 拡張自体が起動していない
//  - エラーが出る      → 起動はしていて、その理由が読める
//  - 件数が出る        → 渡せた
//
//  の 3 つが切り分けられる。ユーザーにとっても、渡ったかどうかが
//  分かるほうが親切ではある。
//
//  `NSExtensionMainStoryboard` は使わず `NSExtensionPrincipalClass` に
//  このクラスを直接指定する。ストーリーボードを持たないぶん project.yml が
//  短くなり、XcodeGen だけで完結する。

import UIKit
import UniformTypeIdentifiers

/// `@objc(ShareViewController)` が要る。
///
/// Info.plist の `NSExtensionPrincipalClass` は Objective-C ランタイムの
/// クラス名で引かれる。Swift のクラスは既定で `QSProbeShare.ShareViewController`
/// のようにモジュール名が付くため、`ShareViewController` では見つからない。
/// 見つからないと **拡張は共有シートに出るのに起動しない**。
/// 何のエラーも出ずに沈黙するので、原因が非常に分かりにくい。
///
/// `$(PRODUCT_MODULE_NAME).ShareViewController` と書く手もあるが、
/// Info.plist の変数展開に依存しないこちらのほうが確実。
@objc(ShareViewController)
class ShareViewController: UIViewController {

    /// 1 回の共有で受ける上限。共有シート側の宣言 (Info.plist の
    /// NSExtensionActivationRule) と揃えておく。
    private static let maxItems = 100

    /// 拡張には診断ログ画面が無く、Mac 無しでは Console も見られない。
    /// 共有コンテナにテキストで残し、ホスト側が取り込み時に読み上げる。
    private func log(_ message: String) {
        NSLog("[QSProbeShare] %@", message)
        SharedAppGroup.appendExtensionLog(message)
    }

    private let card = UIView()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()

        // 何よりも先に足跡を残す。
        //
        // 「拡張が一度も起動していない」のか「起動したあと落ちた」のかは、
        // ここに 1 行あるかどうかで切り分けられる。共有コンテナが解決
        // できない場合はこの行も残らないが、そのときは画面にエラーが出る。
        log("--- 拡張が起動しました ---")

        Task {
            await run()
        }
    }

    // MARK: - 画面

    private func buildUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        statusLabel.text = "QSProbe に渡しています…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        closeButton.setTitle("閉じる", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(closeButton)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),

            statusLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            closeButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            closeButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
    }

    @objc private func closeTapped() {
        finish()
    }

    /// 結果を出す。
    ///
    /// - Parameter autoDismiss: 成功時は短く見せて自動で閉じる。
    ///   失敗時は読む時間が要るので閉じるボタンを出して待つ。
    private func show(_ message: String, autoDismiss: Bool) {
        statusLabel.text = message
        closeButton.isHidden = autoDismiss

        guard autoDismiss else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finish()
        }
    }

    // MARK: - 本体

    private func run() async {
        guard let inbox = SharedAppGroup.inboxURL else {
            // App Group が解決できない = 共有コンテナが無い。
            // ここで詰まると原因が分かりにくいので、必ずログに残す。
            log("✗ App Group を解決できませんでした。ファイルを渡せません")
            let own = SharedAppGroup.profileAppGroups(in: Bundle.main.bundleURL)
            let host = SharedAppGroup.profileAppGroups(in: SharedAppGroup.hostBundleURL)
            show("""
                共有フォルダを開けませんでした。

                拡張: \(own.isEmpty ? "(なし)" : own.joined(separator: ", "))
                本体: \(host.isEmpty ? "(なし)" : host.joined(separator: ", "))
                """, autoDismiss: false)
            return
        }

        let providers = collectProviders()
        guard !providers.isEmpty else {
            log("✗ 添付物がありませんでした")
            show("添付物がありませんでした。", autoDismiss: false)
            return
        }

        do {
            let directory = try SharePayload.makeDropDirectory(in: inbox)
            var items: [SharePayload.Item] = []

            for provider in providers.prefix(Self.maxItems) {
                if let item = await stage(provider: provider, into: directory) {
                    items.append(item)
                }
            }

            guard !items.isEmpty else {
                // 1 件も取り出せなかったらフォルダごと捨てる。
                // 空のフォルダを残すとホスト側の走査に引っかかる。
                try? FileManager.default.removeItem(at: directory)
                log("✗ 添付物を 1 件も取り出せませんでした")
                let types = providers
                    .flatMap { $0.registeredTypeIdentifiers }
                    .joined(separator: ", ")
                show("""
                    ファイルを取り出せませんでした。

                    型: \(types)
                    """, autoDismiss: false)
                return
            }

            // 実体を置き終えてから書く。順序が逆だと取り込み側が
            // 途中のフォルダを読んでしまう。
            let payload = SharePayload(createdAt: Date(), items: items)
            try payload.write(to: directory)

            let group = SharedAppGroup.identifier ?? "(不明)"
            log("★ \(items.count) 件を渡しました (\(directory.lastPathComponent)) — \(group)")
            // グループ ID まで出す。ホスト側と食い違っていたら、渡したのに
            // 見つからないという分かりにくい状態になるため。
            show("""
                \(items.count) 件を QSProbe に渡しました。

                \(group)
                """, autoDismiss: true)
            openHostApp()
        } catch {
            log("✗ 受け渡しに失敗: \(error.localizedDescription)")
            show("受け渡しに失敗しました。\n\(error.localizedDescription)", autoDismiss: false)
        }
    }

    /// 入力から `NSItemProvider` を集める。
    private func collectProviders() -> [NSItemProvider] {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        return inputItems.compactMap { $0.attachments }.flatMap { $0 }
    }

    // MARK: - 1 件を共有コンテナへ

    /// `NSItemProvider` から実体を取り出してコピーする。
    ///
    /// 写真アプリからの共有はファイルパスではなくデータとして渡ってくるので、
    /// `loadFileRepresentation` に一時ファイルを作らせ、それを共有コンテナへ
    /// 移す。渡された一時ファイルはクロージャを抜けると消えるため、
    /// クロージャの中でコピーを完了させる必要がある。
    private func stage(provider: NSItemProvider, into directory: URL) async -> SharePayload.Item? {
        guard let type = preferredType(of: provider) else {
            log("✗ 扱える型がありませんでした — \(provider.registeredTypeIdentifiers.joined(separator: ", "))")
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    self.log("✗ 読み出しに失敗: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let name = provider.suggestedName.map { suggested -> String in
                    // suggestedName に拡張子が無いことがある。実体の拡張子を足す。
                    let ext = url.pathExtension
                    if !ext.isEmpty, !suggested.lowercased().hasSuffix(".\(ext.lowercased())") {
                        return "\(suggested).\(ext)"
                    }
                    return suggested
                } ?? url.lastPathComponent

                let destination = self.uniqueURL(for: name, in: directory)

                do {
                    try FileManager.default.copyItem(at: url, to: destination)

                    let attributes = try? FileManager.default
                        .attributesOfItem(atPath: destination.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

                    continuation.resume(returning: SharePayload.Item(
                        fileName: destination.lastPathComponent,
                        displayName: name,
                        byteCount: size
                    ))
                } catch {
                    self.log("✗ コピーに失敗: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 取り出しに使う型を選ぶ。
    ///
    /// `loadFileRepresentation` は「中身の型」を渡したときに実体を書き出す。
    /// `public.url` や `public.file-url` を渡すと URL 文字列そのものが
    /// 返ってきてしまうので、具体的な型 (public.jpeg, public.mpeg-4 など) を
    /// 優先する。写真アプリは具体型を、ファイル App は具体型と file-url の
    /// 両方を登録してくることが多い。
    private func preferredType(of provider: NSItemProvider) -> String? {
        let excluded: Set<String> = [
            UTType.url.identifier,
            UTType.fileURL.identifier
        ]

        let identifiers = provider.registeredTypeIdentifiers
        if let concrete = identifiers.first(where: { !excluded.contains($0) }) {
            return concrete
        }
        return identifiers.first
    }

    /// 同じ名前が既にあれば連番を足す。
    private func uniqueURL(for name: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        let ext = base.pathExtension
        let stem = base.deletingPathExtension().path
        var counter = 2

        while true {
            var path = "\(stem)-\(counter)"
            if !ext.isEmpty { path += ".\(ext)" }
            let candidate = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: - ホストアプリを起こす

    /// カスタム URL スキームでホストを前面に出す。
    ///
    /// `UIApplication.shared` は拡張では使えないので、レスポンダ連鎖を
    /// 辿って `openURL:` を持つオブジェクトを探す。App Extension から
    /// ホストを開く定番の方法。
    private func openHostApp() {
        guard let url = URL(string: "\(QSProbeURLScheme.scheme)://\(QSProbeURLScheme.shareHost)") else {
            return
        }

        // open(_:options:completionHandler:) は App Extension では
        // 直接呼べないので、セレクタ経由で叩く。
        let selector = NSSelectorFromString("openURL:")

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication,
               application.responds(to: selector) {
                // responds(to:) を確かめてから呼ぶ。応答しないオブジェクトに
                // perform すると例外で拡張ごと落ち、後始末が走らない。
                application.perform(selector, with: url)
                log("ホストアプリを起こしました — \(url)")
                return
            }
            responder = current.next
        }

        log("✗ ホストアプリを起動できませんでした")
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
