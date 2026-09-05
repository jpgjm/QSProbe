//
//  ShareInbox.swift
//  QSProbe
//
//  Share Extension が共有コンテナへ置いたファイルを、ホストアプリへ取り込む。
//
//  ## 共有コンテナに置きっぱなしにしない
//
//  再インストールのたびに共有コンテナの UUID が変わり、中身は消える
//  (実測で確認済み)。またコンテナは拡張とホストの両方が触るので、
//  送信中に別の共有が走ると読み書きが交錯しうる。
//
//  そこで取り込み時に Outbox (アプリ自身の一時領域) へ**移動**し、
//  共有コンテナ側は空にする。以降は写真ピッカー由来のファイルと
//  まったく同じ扱いになる (`isTemporary: true`)。
//
//  ## いつ走らせるか
//
//  2 か所から呼ぶ。
//
//  - 起動時 … アプリが落ちている間に共有されたぶんを拾う
//  - `onOpenURL` … 起動中に共有されたぶんを拾う
//
//  拡張はマニフェストを最後に書くので、`payload.json` があるフォルダ
//  だけを見れば書き込み中のものを掴まずに済む。
//

import Foundation

enum ShareInbox {

    /// 共有コンテナに溜まっているぶんを全部取り込む。
    ///
    /// **アクセスできるグループを全部走査する。** 書き込み側 (拡張) が
    /// こちらと違う ID を選んでいても取りこぼさないための保険。
    ///
    /// 実際に Impactor 署名でこの事故が起きた。署名ツールがバンドルごとに
    /// 専用グループを足すため、ホストは `...48A5LFNW96.48A5LFNW96` を、
    /// 拡張は `...48A5LFNW96` を掴んでいた。拡張は「渡しました」と表示
    /// するのに、ホストには何も見えなかった。
    ///
    /// 選び方は `SharedAppGroup` 側で共通集合を採るよう直したが、
    /// 読むだけなら全部見ても害はないので、二重に手当てしておく。
    ///
    /// - Returns: 送信候補に足せる `PendingItem` の配列。無ければ空。
    static func drain() -> [PendingItem] {
        let groups = SharedAppGroup.allUsableIdentifiers
        guard !groups.isEmpty else {
            // 共有コンテナが無い環境 (App Group が下りていない) では
            // 拡張も動かないので、静かに何もしない。
            return []
        }

        var collected: [PendingItem] = []

        for group in groups {
            // 拡張が残したログを先に読み上げる。共有が空振りしたときでも
            // 拡張側で何が起きたか分かるように、取り込みの有無に関わらず出す。
            for line in SharedAppGroup.drainExtensionLog(in: group) {
                qlog(.info, "共有拡張: \(line)")
            }

            guard let inbox = SharedAppGroup.inboxURL(for: group) else { continue }
            collected.append(contentsOf: drainInbox(inbox, group: group))
        }

        if !collected.isEmpty {
            qlog(.ok, "共有: 共有シートから \(collected.count) 件を取り込みました")
        }

        return collected
    }

    /// 受信箱 1 つぶんを取り込む。
    private static func drainInbox(_ inbox: URL, group: String) -> [PendingItem] {
        let drops = SharePayload.pendingDrops(in: inbox)
        guard !drops.isEmpty else { return [] }

        qlog(.info, "共有: \(group) に \(drops.count) 件の受け渡しがあります")

        var collected: [PendingItem] = []

        for drop in drops {
            guard let payload = SharePayload.read(from: drop) else {
                qlog(.warn, "共有: マニフェストを読めませんでした — \(drop.lastPathComponent)")
                try? FileManager.default.removeItem(at: drop)
                continue
            }

            for item in payload.items {
                let source = drop.appendingPathComponent(item.fileName)
                guard let moved = moveToOutbox(source, displayName: item.displayName) else {
                    continue
                }
                collected.append(PendingItem(
                    url: moved,
                    parentFolder: "",
                    isTemporary: true,
                    scope: nil
                ))
            }

            // マニフェストごと片付ける。失敗しても次回また拾えるよう、
            // 消せなかったこと自体はログに残す。
            do {
                try FileManager.default.removeItem(at: drop)
            } catch {
                qlog(.warn, "共有: 受信箱を片付けられませんでした — "
                    + "\(drop.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return collected
    }

    /// 共有コンテナから Outbox へ移す。
    ///
    /// 同じボリューム上なので `moveItem` はほぼ即座に終わる。
    /// 失敗したときだけコピーにフォールバックする (コンテナをまたぐ
    /// 移動が拒否される可能性に備える)。
    private static func moveToOutbox(_ source: URL, displayName: String) -> URL? {
        let manager = FileManager.default
        let destination = Outbox.uniqueURL(for: displayName)

        do {
            try manager.moveItem(at: source, to: destination)
            return destination
        } catch {
            do {
                try manager.copyItem(at: source, to: destination)
                try? manager.removeItem(at: source)
                return destination
            } catch {
                qlog(.warn, "共有: \(displayName) を取り込めませんでした — "
                    + error.localizedDescription)
                return nil
            }
        }
    }
}
