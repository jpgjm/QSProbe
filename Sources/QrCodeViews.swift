//
//  QrCodeViews.swift
//  QSProbe (M7)
//
//  送信側で表示する QR コードの生成。CoreImage の `CIQRCodeGenerator` を使う。
//  外部ライブラリは不要。
//
//  受信側の QR 読み取りは削除した。Android が出す QR は
//  「ローカル経路」と「Google サーバー中継」の 2 つの入口を兼ねており、
//  ローカル経路は `qr_code_handshake_data` の受信側からの応答が未解明で、
//  30 通りの総当たりでも到達できなかったため。
//  Android → iPad の受信は通常の mDNS 探索で問題なく動く。
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - QR の表示

enum QrCodeImage {

    private static let context = CIContext()

    /// 文字列から QR の `UIImage` を作る。
    ///
    /// 補正レベルは **M (15%)**。Quick Share の URL は 60 文字程度で、
    /// L だと画面越しの読み取りで失敗しやすく、Q/H にするとセルが細かくなりすぎる。
    static func make(from string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // 既定の出力は 1 セル 1 ピクセルなので拡大する。
        // 補間は最近傍でないとセルの境界がぼやけて読み取れなくなる。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QrCodeView: View {
    let text: String
    var side: CGFloat = 240

    var body: some View {
        Group {
            if let image = QrCodeImage.make(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text("QR を生成できませんでした")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
