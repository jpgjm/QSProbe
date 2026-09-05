//
//  AccountSupport.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  PKCE の生成と、継続 (continuation) を 1 回だけ再開させるための小箱。
//

import Foundation
import CryptoKit
import Security

// MARK: - PKCE

enum Pkce {

    /// `code_verifier` に使える文字だけで乱数文字列を作る。
    ///
    /// RFC 7636 の unreserved 文字 (`A-Z a-z 0-9 - . _ ~`) は 66 種類で、
    /// 256 の約数ではないため剰余を取ると僅かに偏りますが、64 文字ぶんの
    /// エントロピーからすると無視できます (それでも 380 ビット以上残る)。
    static func randomURLSafeString(length: Int = 64) -> String {
        let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            for index in 0..<length { bytes[index] = UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// `code_challenge` = base64url(SHA256(verifier))。パディングは付けない。
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64Url.encode(Data(digest))
    }
}

// MARK: - 継続の小箱

/// `withCheckedThrowingContinuation` を**必ず 1 回だけ**再開するための入れ物。
///
/// 認可の待ち受けは「ブラウザからの復帰」と「ループバックへの着信」の
/// 2 経路から終わり得ます。どちらが先に来ても壊れないよう、2 回目以降は
/// 黙って捨てます (継続を 2 回再開するとクラッシュするため)。
///
/// 生成も再開もメインアクター上でのみ行う前提です。
final class ContinuationBox<Value> {

    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    var isPending: Bool { continuation != nil }

    func resume(returning value: Value) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}
