//
//  PasteableField.swift
//  QSProbe
//
//  ペーストと消去のボタンを備えた入力欄。
//
//  ## なぜ要るか
//
//  iPad のソフトウェアキーボードで長い文字列を扱うのは骨が折れる。
//  `client_id` は 70 文字を超えるし、`scope` は URL そのもの。
//  長押しして「ペースト」を選ぶ操作は、指の置き場所を外すと消える。
//
//  「テキストを送る」欄では以前からペーストボタンを出していて具合が良い。
//  同じ作りを、文字を入れるすべての場所に広げる。
//
//  ## 伏字の扱い
//
//  `client_secret` は肩越しに見られたくない値なので、既定で伏せる。
//  ただし**伏せたままだと貼り付けた値が正しいか確かめられない**ので、
//  目のボタンで一時的に出せるようにする。
//

import SwiftUI
import UIKit

struct PasteableField: View {

    let title: String
    let placeholder: String
    @Binding var text: String

    /// 伏字にするか。`client_secret` のような値に使う。
    var isSecret = false

    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                inputField

                if isSecret {
                    button(
                        isRevealed ? "eye.slash" : "eye",
                        label: isRevealed ? "隠す" : "表示"
                    ) {
                        isRevealed.toggle()
                    }
                }

                if text.isEmpty {
                    button("doc.on.clipboard", label: "ペースト") {
                        if let pasted = UIPasteboard.general.string {
                            text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .disabled(!UIPasteboard.general.hasStrings)
                } else {
                    button("xmark.circle.fill", label: "消去") {
                        text = ""
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var inputField: some View {
        if isSecret && !isRevealed {
            SecureField(placeholder, text: $text)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($isFocused)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .lineLimit(1...3)
                .focused($isFocused)
        }
    }

    private func button(
        _ systemName: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(label)
    }
}
