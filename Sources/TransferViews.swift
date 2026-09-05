//
//  TransferViews.swift
//  QSProbe
//
//  受信の同意と、転送中の進捗を出すための部品。
//
//  ## なぜ分けたか
//
//  これまでは受信の状態を「受信」セクションの中に積んでいた。一覧の途中に
//  あるので、送信や設定を触っているうちにスクロールで見失う。
//  取り消すボタンも一緒に流れていくので、押したいときに探すことになっていた。
//
//  性質が違う 2 つを、それぞれに合った形にした。
//
//  | 場面 | 形 | 理由 |
//  |---|---|---|
//  | 同意待ち | sheet | 判断を迫る場面。他を触らせない意味がある |
//  | 転送中 | 上部の固定バナー | 見えていてほしいが、他の操作は続けられるべき |
//
//  転送中まで sheet にすると、ログを見たり設定を変えたりできなくなる。
//  このアプリでは、それは不便すぎる。
//

import SwiftUI

// MARK: - 同意のシート

/// 受け取るかどうかを決めるシート。
struct ConsentSheet: View {

    @ObservedObject var session: InboundSession

    var body: some View {
        NavigationStack {
            List {
                senderSection
                itemsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("受信の確認")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var senderSection: some View {
        Section {
            HStack {
                Text("送信元")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.peerDeviceName ?? "(名前なし)")
                        .font(.body.weight(.medium))
                    if session.peerVerified {
                        Label("署名を検証済み", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("名乗っているだけの名前です")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let pin = session.pinCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("確認コード")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    Text("相手の画面と同じ番号か確かめてください。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(session.files) { file in
                HStack {
                    Text(file.displayPath)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                    Text(ByteFormat.short(file.totalSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(session.texts) { text in
                Text(text.body)
                    .font(.callout)
                    .lineLimit(3)
            }
        } header: {
            Text("受け取るもの (\(session.files.count + session.texts.count) 件)")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                session.reject()
            } label: {
                Label("拒否", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                session.accept()
            } label: {
                Label("受け取る", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.bar)
    }
}

// MARK: - 転送中のバナー

/// 画面の上に貼り付ける、転送中の帯。
///
/// スクロールしても見えるので、進捗を見失わない。
struct TransferBanner: View {

    let title: String
    let subtitle: String
    let progress: Double
    let isSending: Bool
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isSending ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(isSending ? .blue : .green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let onCancel {
                    Button(role: .destructive, action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ProgressView(value: min(max(progress, 0), 1))
                .tint(isSending ? .blue : .green)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - バイト数の表記

enum ByteFormat {

    /// 一覧に並べる用の短い表記。
    static func short(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "サイズ不明" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}
