//
//  BackgroundKeepAlive.swift
//  QSProbe
//
//  無音を鳴らし続けて、アプリをサスペンドさせずに待ち受けを保つ。
//
//  ## なぜ必要か
//
//  `BGContinuedProcessingTask` (iOS 26) は「前面のユーザー操作で始まり、
//  進捗が測れて、終わりが定義できる作業」向けの API で、**終わりの無い常駐**は
//  想定外。WWDC25 セッション 227 が明言している。
//
//  - 進捗を報告しないタスクは時間切れにされ、リソースを回収される
//  - 進捗が想定より遅いと、続けるかどうかをユーザーに訊く UI が出る
//  - 自動で始まる作業 (メンテナンス / バックアップ / 同期) は避けろ
//
//  QSProbe の「このデバイスを見えるようにする」は、まさに終わりの無い待ち受け。
//  相手がいつ送ってくるか分からないので、進捗という概念が無い。よって
//  `BGContinuedProcessingTask` は **転送が始まってから終わるまで**にだけ使い
//  (`BackgroundTransferTask`)、その前段の「待ち受け続ける」はここで面倒を見る。
//
//  ## 仕組み
//
//  `UIBackgroundModes` に `audio` を入れたうえで、無音の WAV を無限ループ再生する。
//  音を鳴らしているあいだ iOS はプロセスをサスペンドしないので、`NWListener` も
//  Bonjour の publish も生きたままになる。entitlement は要らず、`Info.plist` の
//  1 行だけで済む。無料 Personal Team + SideStore でも通る。
//
//  カテゴリは `.playback` + `.mixWithOthers`。`.mixWithOthers` を外すと、他のアプリで
//  再生中の音楽をこちらが奪ってしまう (無音で上書きするので、ユーザーからは
//  「音楽が止まった」ようにしか見えない)。混ぜる指定は必須。
//
//  ## 弱点
//
//  - **バッテリーを食う。** CPU はほぼ使わないが、プロセスが眠らないぶん確実に減る。
//    既定でオフにしてあるのはこのため。
//  - **中断で止まる。** 電話・アラーム・他アプリの排他再生で
//    `AVAudioSession` が中断される。`.ended` を拾って張り直すが、中断中に
//    サスペンドまで進むと通知自体が届かず、前面復帰まで止まったままになる。
//  - **音量ボタンが効く。** 再生中なのでボリューム HUD が「メディア」になる。
//    無音なので実害は無いが、挙動としては覚えておくこと。
//  - 「設定 → 一般 → Appのバックグラウンド更新」とは無関係。あれを切っても効く。
//
//  ## スレッド
//
//  `@MainActor` 専用。通知は `queue: .main` で受け、`Task { @MainActor in }` で入る。
//

import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class BackgroundKeepAlive: ObservableObject {

    enum State: Equatable {
        case stopped
        case running
        /// 電話などで中断された。復帰を待っている。
        case interrupted(String)
        case failed(String)
    }

    /// ユーザーが常駐を望んでいるか。実際の `state` とは分けて持つ。
    /// 広告のトグルと同じ考え方 (意図と実状態の分離)。
    @Published private(set) var isEnabled = false

    @Published private(set) var state: State = .stopped

    /// 生きているかの見張り間隔。中断以外の理由で止まっていたら鳴らし直す。
    private static let watchdogInterval: TimeInterval = 30

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    /// 外す手段は用意していない。このオブジェクトはアプリと同じ寿命で、
    /// `deinit` は `@MainActor` 隔離のプロパティに触れないので書けない。
    private var observers: [NSObjectProtocol] = []

    /// 直前に鳴っていたか。ログを毎回出さないための記憶。
    private var lastLoggedRunning: Bool?

    // MARK: - 操作

    /// トグルの操作。意図を記録したうえで開始 / 停止する。
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
            qlog(.info, "KeepAlive: 常駐を止めました")
        }
    }

    /// 鳴っているか。呼び出し側が「本当に効いているか」を見たいときに使う。
    var isRunning: Bool {
        player?.isPlaying == true
    }

    // MARK: - 開始 / 停止

    private func start() {
        installObserversIfNeeded()

        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers を外すと他アプリの再生を奪う。必ず付ける。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let url = try Self.silenceFileURL()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1   // 無限ループ
            newPlayer.volume = 1.0         // 中身が無音なので音量は関係ない
            newPlayer.prepareToPlay()

            guard newPlayer.play() else {
                throw NSError(
                    domain: "QSProbe.KeepAlive",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() が false を返しました"]
                )
            }

            player = newPlayer
            state = .running
            lastLoggedRunning = true
            startWatchdog()

            qlog(.ok, "KeepAlive: ★ 無音再生を開始しました。"
                + "バックグラウンドでも待ち受けを続けます")
        } catch {
            player = nil
            state = .failed(error.localizedDescription)
            qlog(.error, "KeepAlive: 無音再生を開始できませんでした — \(error.localizedDescription)")
            qlog(.warn, "KeepAlive: バックグラウンドの待ち受けは効きません "
                + "(前面にいるあいだだけ動きます)")
        }
    }

    private func stop() {
        stopWatchdog()

        player?.stop()
        player = nil
        state = .stopped
        lastLoggedRunning = nil

        do {
            // notifyOthersOnDeactivation を付けないと、こちらが抜けたことが
            // 他アプリに伝わらず、相手の再生が再開しないことがある。
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            qlog(.info, "KeepAlive: オーディオセッションの解放に失敗 — "
                + error.localizedDescription)
        }
    }

    /// 止まっていたら鳴らし直す。中断からの復帰と見張りの両方から呼ぶ。
    private func restartIfNeeded(reason: String) {
        guard isEnabled else { return }
        guard !isRunning else { return }

        qlog(.info, "KeepAlive: \(reason)ため鳴らし直します")
        stop()
        start()
    }

    // MARK: - 見張り

    /// 中断通知が届かないまま止まっているケースがある (メディアサービスの再起動、
    /// ルート変更の取りこぼしなど)。定期的に見て、黙って死んでいたら復帰させる。
    private func startWatchdog() {
        stopWatchdog()

        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAlive()
            }
        }
        // スクロール中でも止まらないようにする。
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkAlive() {
        guard isEnabled else { return }

        let running = isRunning
        if running != lastLoggedRunning {
            lastLoggedRunning = running
            if running {
                qlog(.ok, "KeepAlive: 無音再生が続いています")
            } else {
                qlog(.warn, "KeepAlive: 無音再生が止まっていました")
            }
        }

        guard !running else { return }
        if case .interrupted = state {
            // 中断中は勝手に割り込まない。復帰通知を待つ。
            return
        }
        restartIfNeeded(reason: "再生が止まっていた")
    }

    // MARK: - 通知

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                qlog(.warn, "KeepAlive: メディアサービスが再起動しました")
                self.state = .stopped
                self.restartIfNeeded(reason: "メディアサービスが再起動した")
            }
        })

        #if canImport(UIKit)
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                // ここが効いているかどうかが一番知りたい情報なので、必ず残す。
                if self.isRunning {
                    qlog(.ok, "KeepAlive: 背面へ回りましたが無音再生は継続中です")
                } else {
                    qlog(.error, "KeepAlive: 背面へ回った時点で再生が止まっています。"
                        + "まもなくサスペンドされます")
                }
            }
        })
        #endif
    }

    private func handleInterruption(_ note: Notification) {
        guard isEnabled else { return }
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            let reason = Self.interruptionReason(note)
            state = .interrupted(reason)
            lastLoggedRunning = false
            qlog(.warn, "KeepAlive: 再生が中断されました (\(reason))。"
                + "このままだとサスペンドされます")

        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                qlog(.info, "KeepAlive: 中断が終わりました。再開します")
            } else {
                // shouldResume が無くても、こちらは無音なので再開して構わない。
                qlog(.info, "KeepAlive: 中断が終わりました (shouldResume 無し)。再開を試みます")
            }
            state = .stopped
            restartIfNeeded(reason: "中断から復帰した")

        @unknown default:
            break
        }
    }

    private static func interruptionReason(_ note: Notification) -> String {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt,
              let reason = AVAudioSession.InterruptionReason(rawValue: raw) else {
            return "理由不明"
        }
        // 非 frozen enum なので default で受ける。将来ケースが増えても壊れない。
        switch reason {
        case .default:         return "他アプリの再生など"
        case .builtInMicMuted: return "内蔵マイクのミュート"
        default:               return "その他 (raw=\(raw))"
        }
    }

    // MARK: - 無音ファイル

    /// 無音の WAV を tmp に置いて、その URL を返す。
    ///
    /// バイナリをリポジトリに置かず、`project.yml` の resources もいじらずに
    /// 済ませるため、実行時に組み立てる。44.1 kHz / 16 bit / モノラル / 1 秒 =
    /// 約 86 KB。作るのは初回だけ。
    private static func silenceFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qsprobe-silence.wav")

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate = 44_100
        let channels = 1
        let bitsPerSample = 16
        let seconds = 1

        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * blockAlign
        let dataBytes = byteRate * seconds

        var out = Data()
        func put32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }

        out.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + dataBytes))              // このあとに続くバイト数
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)                                  // fmt チャンクの長さ
        put16(1)                                   // 1 = リニア PCM
        put16(UInt16(channels))
        put32(UInt32(sampleRate))
        put32(UInt32(byteRate))
        put16(UInt16(blockAlign))
        put16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        put32(UInt32(dataBytes))
        out.append(Data(count: dataBytes))         // 全部ゼロ = 無音

        try out.write(to: url, options: .atomic)
        qlog(.info, "KeepAlive: 無音ファイルを作成しました (\(out.count) バイト)")
        return url
    }
}
