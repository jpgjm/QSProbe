//
//  LoopbackRedirectServer.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  `http://127.0.0.1:<port>/oauth2redirect` を受けるための、寿命の短い
//  HTTP サーバ。デスクトップ型の OAuth クライアントはこの形しか
//  リダイレクト先に認めないため、iOS 側でも同じ受け口を用意します。
//
//  ## なぜ端末内で完結するのか
//
//  認可画面は `ASWebAuthenticationSession` (別プロセス) が表示しますが、
//  `127.0.0.1` は**プロセスではなく端末に閉じた**アドレスなので、
//  そこからこちらの listener に届きます。外部 Safari で開くと QSProbe が
//  背面に回って listener ごと止められてしまうため、必ず
//  `ASWebAuthenticationSession` 側から開きます。
//
//  ## 待ち受けるアドレス
//
//  `requiredLocalEndpoint` で **127.0.0.1 だけ**に束縛します。全インタフェース
//  で待つと、同じ Wi-Fi の他人が認可コードを取りに来られる余地が生まれます。
//  ループバックなのでローカルネットワーク権限とも無関係です。
//
//  ## 寿命
//
//  認可 1 回につき生成し、コードを受け取るか中断された時点で必ず閉じます。
//

import Foundation
import Network

enum LoopbackError: Error, CustomStringConvertible {
    case listenerFailed(String)
    case noPort
    case cancelled

    var description: String {
        switch self {
        case .listenerFailed(let detail): return "ループバックの待ち受けに失敗しました: \(detail)"
        case .noPort: return "ループバックのポートを取得できませんでした"
        case .cancelled: return "ループバックの待ち受けが閉じられました"
        }
    }
}

@MainActor
final class LoopbackRedirectServer {

    /// 認可コードを載せたリダイレクトが届いたときに 1 回だけ呼ばれる。
    var onRedirect: ((URL) -> Void)?

    /// 待ち受け自体が壊れたときに呼ばれる。
    var onFailure: ((String) -> Void)?

    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var readyBox: ContinuationBox<UInt16>?
    private var didDeliver = false

    // MARK: - 開始 / 停止

    /// 待ち受けを開始し、割り当てられたポート番号を返す。
    func start() async throws -> UInt16 {
        stop()
        didDeliver = false

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw LoopbackError.listenerFailed("\(error)")
        }
        listener = newListener

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<UInt16>(continuation)
            readyBox = box

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            newListener.start(queue: .main)
        }
    }

    func stop() {
        readyBox?.resume(throwing: LoopbackError.cancelled)
        readyBox = nil

        for connection in connections { connection.cancel() }
        connections.removeAll()

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = 0

        // 閉じたあとまで ASWebAuthenticationSession を掴んだままにしない。
        onRedirect = nil
        onFailure = nil
    }

    // MARK: - listener の状態

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener?.port?.rawValue, value != 0 else {
                readyBox?.resume(throwing: LoopbackError.noPort)
                readyBox = nil
                return
            }
            port = value
            qlog(.ok, "Account: ループバックの待ち受けを開始しました (127.0.0.1:\(value))")
            readyBox?.resume(returning: value)
            readyBox = nil

        case .failed(let error):
            let detail = "\(error)"
            qlog(.error, "Account: ループバックの待ち受けが失敗しました — \(detail)")
            readyBox?.resume(throwing: LoopbackError.listenerFailed(detail))
            readyBox = nil
            onFailure?(detail)

        case .cancelled:
            readyBox?.resume(throwing: LoopbackError.cancelled)
            readyBox = nil

        default:
            break
        }
    }

    // MARK: - 着信

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readRequest(from: connection)
                case .failed, .cancelled:
                    self.connections.removeAll { $0 === connection }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func readRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] content, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    qlog(.warn, "Account: ループバックの受信でエラー — \(error)")
                    connection.cancel()
                    return
                }
                guard let content, !content.isEmpty,
                      let text = String(data: content, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.handleRequest(text, on: connection)
            }
        }
    }

    /// リクエスト行から取り出したパスを URL に組み直して通知する。
    private func handleRequest(_ text: String, on connection: NWConnection) {
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else {
            respond(on: connection, status: "400 Bad Request", body: badRequestPage)
            return
        }

        let path = String(fields[1])

        // ブラウザは favicon も取りに来る。認可の応答と紛らわしいので弾く。
        if path.hasPrefix("/favicon") {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            respond(on: connection, status: "400 Bad Request", body: badRequestPage)
            return
        }

        // クエリを持たない要求 (`/` への直アクセスなど) は無視して待ち続ける。
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            respond(on: connection, status: "200 OK", body: waitingPage)
            return
        }

        guard !didDeliver else {
            respond(on: connection, status: "200 OK", body: donePage)
            return
        }
        didDeliver = true

        let hasError = items.contains { $0.name == "error" }
        respond(on: connection, status: "200 OK", body: hasError ? deniedPage : donePage)
        onRedirect?(url)
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 返すページ

    private var donePage: String {
        page(title: "認可が終わりました", message: "QSProbe に戻ってください。")
    }

    private var deniedPage: String {
        page(title: "認可されませんでした", message: "QSProbe に戻って、ログを確認してください。")
    }

    private var badRequestPage: String {
        page(title: "解釈できない要求です", message: "QSProbe に戻ってください。")
    }

    private var waitingPage: String {
        page(title: "QSProbe", message: "認可の応答を待っています。")
    }

    private func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="ja"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>QSProbe</title></head>
        <body style="font-family:-apple-system,sans-serif;padding:2em;line-height:1.6">
        <h2>\(title)</h2><p>\(message)</p></body></html>
        """
    }
}
