//
//  QSProbeApp.swift
//  QSProbe
//
//  Quick Share iOS 移植プロジェクトの M0 検証アプリ。
//  プロトコルは一切喋らず、mDNS の広告と探索だけを行う。
//

import SwiftUI

@main
struct QSProbeApp: App {

    init() {
        // 継続実行タスクのハンドラ登録。転送のたびではなく、起動時に 1 度だけ。
        // 登録前に submit しても OS はハンドラを呼べないので、ここが最初でよい。
        BackgroundTransferTask.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
