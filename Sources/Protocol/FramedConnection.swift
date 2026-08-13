//
//  FramedConnection.swift
//  QSProbe (M1)
//
//  Bada の `core-protocol/.../transport/FramedConnection.kt` に対応する層。
//  NearDrop / QuickDrop の `NearbyConnection.receiveFrameAsync()` と同じ
//  ワイヤフォーマットを扱う。
//
//  Quick Share の TCP 上では、すべてのメッセージが
//  **4 バイトのビッグエンディアン長さプレフィックス**で区切られる。
//  この層はペイロードの中身を一切解釈せず、フレームの切り出しだけを行う。
//
//  異常フレーム対策として 5 MiB の上限を設けている (NearDrop と同値)。
//

import Foundation
import Network

enum FramedConnectionError: Error, CustomStringConvertible {
    case closedByPeer
    case frameTooLarge(UInt32)
    case truncated(expected: Int, got: Int)
    case network(NWError)

    var description: String {
        switch self {
        case .closedByPeer:
            return "相手が接続を閉じました"
        case .frameTooLarge(let size):
            return "フレームが大きすぎます (\(size) バイト)"
        case .truncated(let expected, let got):
            return "フレームが途中で切れました (期待 \(expected) / 実際 \(got))"
        case .network(let error):
            return "ネットワークエラー: \(error)"
        }
    }
}

final class FramedConnection {

    /// NearDrop と同じ 5 MiB のサニティ上限。
    static let maxFrameSize: UInt32 = 5 * 1024 * 1024

    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// 1 フレーム分のペイロードを読み出す。
    func receiveFrame(completion: @escaping (Result<Data, FramedConnectionError>) -> Void) {
        // 1) 長さプレフィックス 4 バイト
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, isComplete, error in
            if let error {
                completion(.failure(.network(error)))
                return
            }
            guard let header = content, header.count == 4 else {
                if isComplete {
                    completion(.failure(.closedByPeer))
                } else {
                    completion(.failure(.truncated(expected: 4, got: content?.count ?? 0)))
                }
                return
            }

            let length = header.withUnsafeBytes { raw -> UInt32 in
                var value: UInt32 = 0
                for byte in raw {
                    value = (value << 8) | UInt32(byte)
                }
                return value
            }

            guard length > 0 else {
                completion(.success(Data()))
                return
            }
            guard length <= Self.maxFrameSize else {
                completion(.failure(.frameTooLarge(length)))
                return
            }

            // 2) ペイロード本体
            self.receiveExactly(Int(length), completion: completion)
        }
    }

    private func receiveExactly(
        _ count: Int,
        completion: @escaping (Result<Data, FramedConnectionError>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
            if let error {
                completion(.failure(.network(error)))
                return
            }
            guard let payload = content, payload.count == count else {
                if isComplete {
                    completion(.failure(.closedByPeer))
                } else {
                    completion(.failure(.truncated(expected: count, got: content?.count ?? 0)))
                }
                return
            }
            completion(.success(payload))
        }
    }

    /// 長さプレフィックスを付けて 1 フレーム送信する。
    func sendFrame(_ payload: Data, completion: ((NWError?) -> Void)? = nil) {
        var out = Data(capacity: 4 + payload.count)
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(payload)

        connection.send(content: out, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    func cancel() {
        connection.cancel()
    }
}
