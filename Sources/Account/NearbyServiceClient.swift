//
//  NearbyServiceClient.swift
//  QSProbe
//
//  `google.nearby.identity.v1.NearbyService` を叩く手書きの gRPC クライアント。
//
//  ## なぜ手書きなのか
//
//  `grpc-swift` は正当だが、SwiftNIO と多数のモジュール依存を引き込むため、
//  iOS のバイナリサイズとビルド時間が跳ねる。使うのは unary RPC だけで、
//  それは `URLSession` の上に薄く実装できる。SwiftProtobuf は既に依存しているので、
//  proto の直列化はそのまま使える。
//
//  ## gRPC over HTTP/2 の framing
//
//  リクエスト・レスポンスとも、**1 メッセージにつき 5 バイトのプレフィックス**が付く。
//
//  ```
//  +------+---------------------+ ...
//  | 1 B  | 4 B (big endian)    | protobuf ボディ
//  +------+---------------------+ ...
//   圧縮   メッセージ長
//   0=無し
//  ```
//
//  レスポンスは HTTP が 200 で返り、gRPC のエラーは trailer の `grpc-status` に載る。
//  `URLSession` は HTTP/2 の trailer を素直には取れないので、
//  レスポンスヘッダ側の `grpc-status` を優先して見て、無ければ本体の
//  proto が正しく解けるかどうかで判定する。
//
//  ## 副作用
//
//  第 2 段で扱う `GetAccountInfo` は**読み取り専用**で、Google アカウントに
//  何も書き込まない。第 3 段の `PublishDevice` はアカウントに端末を登録するので、
//  必ずサブアカウントで確認すること。
//

import Foundation
import SwiftProtobuf

/// GFE がこのエンドポイントに何を許すかを実測した結果、**`.grpc` だけが通る**。
/// 切り分けの記録として 3 通りを残してある。
///
/// ```
/// grpc+proto → HTTP 404 / text/html          gRPC と認識されない
/// grpc       → HTTP 200 / application/grpc   grpc-status がヘッダに載る ★
/// $rpc       → HTTP 404 / text/html          この host には無い
/// ```
///
/// | 方式 | Content-Type | URL パス | ボディ |
/// |---|---|---|---|
/// | `.grpcProto` | `application/grpc+proto` | `/svc/Method` | 5 バイト + protobuf |
/// | `.grpc`      | `application/grpc`       | `/svc/Method` | 5 バイト + protobuf |
/// | `.xprotobuf` | `application/x-protobuf` | `/$rpc/svc/Method` | protobuf そのまま |
///
/// `.xprotobuf` は gRPC ではなく、Google の一部 1P API が使う**素の protobuf を POST する**方式。
/// `/$rpc/` プレフィックスはドキュメントに無い Google 内部の慣習。
/// `nearby.googleapis.com` に対して**実測で通った運び方だけ**を残してある。
///
/// 試して落ちたものは、同じことを繰り返さないためにここに書いておく。
///
/// ```
/// application/grpc+proto      HTTP 404 / text/html   gRPC と認識されない
/// application/grpc-web+proto  HTTP 404 / text/html   GFE が受けない
/// ```
///
/// 選択肢に残しておくと、うっかり選んで丸ごと 404 になるだけなので消した。
/// 保存済みの設定が消した値を指していても、`init?(rawValue:)` が nil を返して
/// `.grpc` に落ちるので実害は無い。
enum NearbyWireFormat: String, CaseIterable {

    /// 素の gRPC。5 バイトの前置き付き。応答も同じ形。
    ///
    /// 失敗は trailers-only 応答になるので `grpc-status` がヘッダに出る。
    /// 成功して本体が空の場合、trailer は HTTP/2 側に載って `URLSession` からは
    /// 見えない。つまり「空の成功」と「本文なしの失敗」が区別できない。
    case grpc = "application/grpc"

    /// `/$rpc/` 配下に素の protobuf を POST する形。Google の 1P ウェブ
    /// クライアントが `-pa` 系を叩くときの流儀。
    ///
    /// gRPC の枠が無いぶん、**失敗が素の HTTP ステータスで返る**。
    /// trailer を読む必要が無いので、`URLSession` との相性はこちらが良い。
    case xprotobuf = "application/x-protobuf"

    var label: String {
        switch self {
        case .grpc: return "grpc"
        case .xprotobuf: return "$rpc / x-protobuf"
        }
    }

    var usesGrpcFraming: Bool {
        self == .grpc
    }

    var pathPrefix: String {
        switch self {
        case .grpc: return ""
        case .xprotobuf: return "/$rpc"
        }
    }

    /// 応答の末尾に trailer フレームが載る形式か。
    ///
    /// いまはどちらも該当しないが、フレーム走査側の分岐を残しておく。
    var carriesTrailerFrame: Bool { false }

    /// 順に試すときの並び。素の gRPC を先に見る。
    static let usable: [NearbyWireFormat] = [.grpc, .xprotobuf]
}

@MainActor
final class NearbyServiceClient {

    /// 既定は `.grpc`。
    ///
    /// 実測で確定した事実: `application/grpc+proto` は GFE に gRPC として
    /// 認識されず、素の HTTP 要求とみなされて **HTML の 404** が返る。
    /// `application/grpc` にすると正しく gRPC として処理され、
    /// `grpc-status` がヘッダに載って返ってくる。仕様上はどちらも有効な
    /// はずだが、Google のフロントエンドは前者を受け付けない。
    var wireFormat: NearbyWireFormat = .grpc


    enum ClientError: Error, LocalizedError {
        case notSignedIn
        case http(status: Int, body: Data)
        case grpc(code: Int, message: String)
        case emptyResponse
        case shortResponse(Int)
        case truncatedFrame(declared: UInt32, actual: Int)
        case protoDecode(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "サインインしていません"
            case .http(let status, _):
                return "HTTP \(status)"
            case .grpc(let code, let message):
                return "gRPC \(code) — \(message) (\(Self.grpcStatusName(code)))"
            case .emptyResponse:
                return "応答が空です"
            case .shortResponse(let n):
                return "応答が短すぎます (\(n) バイト)"
            case .truncatedFrame(let declared, let actual):
                return "フレーム長 \(declared) が実長 \(actual) を超えます"
            case .protoDecode(let detail):
                return "proto デコードに失敗 — \(detail)"
            }
        }

        /// `grpc-status` の数値に対応する定数名。切り分けに使う。
        static func grpcStatusName(_ code: Int) -> String {
            switch code {
            case 0:  return "OK"
            case 1:  return "CANCELLED"
            case 2:  return "UNKNOWN"
            case 3:  return "INVALID_ARGUMENT"
            case 5:  return "NOT_FOUND"
            case 7:  return "PERMISSION_DENIED"     // クライアントに権限が無い
            case 8:  return "RESOURCE_EXHAUSTED"
            case 12: return "UNIMPLEMENTED"
            case 13: return "INTERNAL"
            case 14: return "UNAVAILABLE"
            case 16: return "UNAUTHENTICATED"       // トークンが無効
            default: return "UNKNOWN(\(code))"
            }
        }
    }

    /// 疎通確認だけを行うのが第 2 段の役目なので、他の RPC はここに足していく。
    func getAccountInfo(accessToken: String) async throws -> NearbyAccountInfo {
        let response = try await callUnary(
            method: "GetAccountInfo",
            request: NearbyGetAccountInfoRequest(),
            accessToken: accessToken,
            responseType: NearbyGetAccountInfoResponse.self
        )
        return response.accountInfo
    }

    /// 証明書の検証に使う根の公開鍵を取る。読み取り専用。
    ///
    /// 応答は `…Response` で包まれておらず、`IdentityBrokerConfig` そのもの。
    func getIdentityBrokerConfig(
        name: String, accessToken: String
    ) async throws -> NearbyIdentityBrokerConfig {
        try await callUnary(
            method: "GetIdentityBrokerConfig",
            request: NearbyGetIdentityBrokerConfigRequest(name: name),
            accessToken: accessToken,
            responseType: NearbyIdentityBrokerConfig.self
        )
    }

    /// 端末と証明書をアカウントに登録する。**書き込み。**
    ///
    /// これを呼ぶと、Google アカウントのデバイス一覧にこの端末が載る。
    /// 読み取り専用の呼び出しと違い、取り消しには別の操作が要る。
    func publishDevice(
        _ request: NearbyPublishDeviceRequest, accessToken: String
    ) async throws -> NearbyPublishDeviceResponse {
        try await callUnary(
            method: "PublishDevice",
            request: request,
            accessToken: accessToken,
            responseType: NearbyPublishDeviceResponse.self
        )
    }

    /// 相手の `SharedCredential` (= 公開証明書) を取る。読み取り専用。
    ///
    /// `name` は `devices/{device_id}` の形。`device_id` の出どころは未確定で、
    /// `GetAccountInfo` の `current_dusi` がそのまま使えるかを試している段階。
    func querySharedCredentials(
        name: String, pageSize: Int32 = 0, pageToken: String = "", accessToken: String
    ) async throws -> NearbyQuerySharedCredentialsResponse {
        try await callUnary(
            method: "QuerySharedCredentials",
            request: NearbyQuerySharedCredentialsRequest(
                name: name, pageSize: pageSize, pageToken: pageToken
            ),
            accessToken: accessToken,
            responseType: NearbyQuerySharedCredentialsResponse.self
        )
    }

    // MARK: - 中核

    private func callUnary<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        method: String,
        request: Req,
        accessToken: String,
        responseType: Resp.Type
    ) async throws -> Resp {

        let body = try request.serializedData()
        let payload: Data
        if wireFormat.usesGrpcFraming {
            // gRPC のフレーム: [1 バイト圧縮フラグ][4 バイト長 BE][ボディ]
            var buf = Data()
            buf.append(0)
            var length = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &length) { buf.append(contentsOf: $0) }
            buf.append(body)
            payload = buf
        } else {
            // 素の protobuf。gRPC のプレフィックスは付けない。
            payload = body
        }

        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = AccountConfig.grpcHost
        comp.path = "\(wireFormat.pathPrefix)/\(AccountConfig.grpcService)/\(method)"
        guard let url = comp.url else {
            throw ClientError.http(status: 0, body: Data())
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(wireFormat.rawValue, forHTTPHeaderField: "Content-Type")
        if wireFormat.usesGrpcFraming {
            req.setValue("trailers", forHTTPHeaderField: "TE")
            req.setValue("identity", forHTTPHeaderField: "Grpc-Accept-Encoding")
        }
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("QSProbe/experimental grpc-manual", forHTTPHeaderField: "User-Agent")
        req.httpBody = payload

        qlog(.info, "Account gRPC: → \(method) "
            + "(方式=\(wireFormat.label), body=\(body.count) バイト, "
            + "payload=\(payload.count) バイト, path=\(comp.path))")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.emptyResponse
        }

        qlog(.info, "Account gRPC: ← HTTP \(http.statusCode), \(data.count) バイト")
        logResponseHeaders(http)

        // gRPC のステータスがヘッダに来ていれば、そちらを優先する。
        // 一部のゲートウェイは HTTP 200 + trailer で失敗を返してくるが、
        // それを URLSession が取り零すことがあるため、ヘッダ側も見る。
        if let grpcStatus = http.value(forHTTPHeaderField: "grpc-status"),
           let code = Int(grpcStatus), code != 0 {
            let message = http.value(forHTTPHeaderField: "grpc-message") ?? ""
            qlog(.error, "Account gRPC: ✗ grpc-status = \(code) (\(ClientError.grpcStatusName(code)))")
            if !message.isEmpty {
                qlog(.error, "Account gRPC:   \(message)")
            }
            throw ClientError.grpc(code: code, message: message)
        }

        guard http.statusCode == 200 else {
            // $rpc の失敗本体は `google.rpc.Status` の protobuf。
            // field 1 = code (varint), field 2 = message (string)。
            if let status = Self.parseRpcStatus(data) {
                qlog(.error, "Account gRPC: ✗ \(status.code) "
                    + "(\(ClientError.grpcStatusName(status.code))) — \(status.message)")
                throw ClientError.grpc(code: status.code, message: status.message)
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
            qlog(.error, "Account gRPC: HTTP エラー本体 = \(preview)")
            throw ClientError.http(status: http.statusCode, body: data)
        }

        if data.isEmpty {
            if wireFormat.usesGrpcFraming {
                // gRPC の枠すら無い = 本体が無く trailer だけ。
                // 失敗の理由は HTTP/2 側に載って見えない。
                qlog(.warn, "Account gRPC: 応答が 0 バイトです "
                    + "(trailer だけで返っている可能性)")
                qlog(.warn, "Account gRPC: → $rpc 方式なら失敗が HTTP ステータスで返ります")
                throw ClientError.emptyResponse
            }
            // $rpc は素の protobuf。失敗なら HTTP が 200 以外になるので、
            // ここに来た 0 バイトは「全フィールドが既定値の応答」で正しい。
            qlog(.info, "Account gRPC: 0 バイトの応答 = 空のメッセージ (成功)")
            return try Resp()
        }

        let respBody: Data
        if wireFormat.usesGrpcFraming {
            guard data.count >= 5 else {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                qlog(.error, "Account gRPC: 短すぎる応答 hex = \(hex)")
                throw ClientError.shortResponse(data.count)
            }

            // フレームを順に取り出す。0x80 が立っているものは trailer。
            var message: Data?
            for frame in Self.frames(in: data) {
                if frame.flag & 0x80 != 0 {
                    let fields = Self.parseTrailer(frame.body)
                    if let raw = fields["grpc-status"], let code = Int(raw), code != 0 {
                        let detail = fields["grpc-message"]?.removingPercentEncoding
                            ?? fields["grpc-message"] ?? ""
                        qlog(.error, "Account gRPC: ✗ trailer の grpc-status = \(code) "
                            + "(\(ClientError.grpcStatusName(code)))")
                        if !detail.isEmpty {
                            qlog(.error, "Account gRPC:   \(detail)")
                        }
                        throw ClientError.grpc(code: code, message: detail)
                    }
                    qlog(.info, "Account gRPC: trailer フレーム = grpc-status 0 (OK)")
                } else if message == nil {
                    message = frame.body
                }
            }

            guard let message else {
                // 本体フレームが 1 つも無い。gRPC としては「空の成功」か、
                // 失敗の trailer が HTTP/2 側に載って取り零されたかのどちらか。
                qlog(.warn, "Account gRPC: 本体フレームがありません "
                    + "(\(data.count) バイト)")
                if !wireFormat.carriesTrailerFrame {
                    qlog(.warn, "Account gRPC: → grpc-web に切り替えると "
                        + "trailer が本体末尾に載るので、成否を判別できます")
                }
                throw ClientError.emptyResponse
            }
            respBody = message
            qlog(.info, "Account gRPC: 応答本体 \(respBody.count) バイト")
        } else {
            // gRPC のプレフィックスは無いので、全部が protobuf 本体
            respBody = data
            qlog(.info, "Account gRPC: 応答本体 \(respBody.count) バイト (プレフィックス無し方式)")
        }

        do {
            let resp = try Resp(serializedBytes: respBody)
            return resp
        } catch {
            let hex = respBody.prefix(120).map { String(format: "%02x", $0) }.joined()
            qlog(.error, "Account gRPC: proto デコード失敗 — \(error)")
            qlog(.error, "Account gRPC:   本体 hex(先頭 120) = \(hex)")
            throw ClientError.protoDecode(String(describing: error))
        }
    }

    // MARK: - 経路の総当たり

    /// 1 本のパスを叩いた結果。中身は見ず、**経路があるかどうか**だけを判定する。
    struct ProbeOutcome {
        let host: String
        let path: String

        /// ログ表示用の宛先。
        var target: String { "\(host)\(path)" }

        let httpStatus: Int
        let contentType: String
        let grpcStatus: Int?
        let grpcMessage: String?
        let bodyBytes: Int

        /// そのパスに実装があると言えるか。
        ///
        /// `UNIMPLEMENTED` (12) は「そこには無い」。HTML の 404 は
        /// 「gRPC ですらない」。それ以外 —— 成功でも `PERMISSION_DENIED` でも
        /// `INVALID_ARGUMENT` でも —— **ハンドラまで届いた証拠**になる。
        var looksImplemented: Bool {
            if contentType.contains("text/html") { return false }
            if httpStatus == 404 { return false }
            guard let grpcStatus else { return httpStatus == 200 }
            return grpcStatus != 12
        }

        var summary: String {
            var parts = ["HTTP \(httpStatus)"]
            if let grpcStatus {
                parts.append("grpc-status=\(grpcStatus) "
                    + "(\(ClientError.grpcStatusName(grpcStatus)))")
            } else if !contentType.isEmpty {
                parts.append(contentType)
            }
            parts.append("\(bodyBytes) バイト")
            return parts.joined(separator: " / ")
        }
    }

    /// 空のリクエストで 1 本だけ叩く。例外は投げず、結果をそのまま返す。
    ///
    /// **書き込み系のメソッドは渡さないこと。** 経路が当たっていた場合、
    /// ハンドラが実際に走る。`UNIMPLEMENTED` はハンドラの手前で返るので
    /// 副作用は無いが、当たったときは走ってしまう。
    func probe(host: String, path: String, accessToken: String) async -> ProbeOutcome {
        // gRPC のフレーム。空メッセージなので中身は 0 バイト。
        var payload = Data()
        payload.append(0)
        payload.append(contentsOf: [0, 0, 0, 0])

        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = host
        comp.path = path

        guard let url = comp.url else {
            return ProbeOutcome(host: host, path: path, httpStatus: 0, contentType: "",
                                grpcStatus: nil, grpcMessage: "URL を組み立てられません",
                                bodyBytes: 0)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(NearbyWireFormat.grpc.rawValue, forHTTPHeaderField: "Content-Type")
        req.setValue("trailers", forHTTPHeaderField: "TE")
        req.setValue("identity", forHTTPHeaderField: "Grpc-Accept-Encoding")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(AccountConfig.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            var code: Int?
            if let raw = http?.value(forHTTPHeaderField: "grpc-status") {
                code = Int(raw)
            }
            return ProbeOutcome(
                host: host,
                path: path,
                httpStatus: http?.statusCode ?? -1,
                contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                grpcStatus: code,
                grpcMessage: http?.value(forHTTPHeaderField: "grpc-message"),
                bodyBytes: data.count
            )
        } catch {
            return ProbeOutcome(host: host, path: path, httpStatus: -1, contentType: "",
                                grpcStatus: nil, grpcMessage: error.localizedDescription,
                                bodyBytes: 0)
        }
    }

    /// 複数のパスを順に叩き、実装がありそうなものだけを返す。
    @discardableResult
    func probePaths(
        hosts: [String], paths: [String], accessToken: String
    ) async -> [ProbeOutcome] {
        let total = hosts.count * paths.count
        qlog(.info, "Account gRPC: ==== 総当たり (ホスト \(hosts.count) × 経路 "
            + "\(paths.count) = \(total) 本) ====")

        var hits: [ProbeOutcome] = []
        for host in hosts {
            for path in paths {
                let outcome = await probe(host: host, path: path, accessToken: accessToken)
                if outcome.looksImplemented {
                    hits.append(outcome)
                    qlog(.ok, "Account gRPC: ★ \(outcome.target)")
                    qlog(.ok, "Account gRPC:     \(outcome.summary)")
                    if let message = outcome.grpcMessage, !message.isEmpty {
                        qlog(.info, "Account gRPC:     \(message)")
                    }
                } else {
                    qlog(.info, "Account gRPC: ✗ \(outcome.target) — \(outcome.summary)")
                }
            }
        }

        if hits.isEmpty {
            qlog(.warn, "Account gRPC: ==== 当たり無し。すべて UNIMPLEMENTED か 404 ====")
        } else {
            qlog(.ok, "Account gRPC: ==== 当たり \(hits.count) 本 ====")
        }
        return hits
    }

    // MARK: - google.rpc.Status

    /// `google.rpc.Status` を最小限だけ読む。
    ///
    /// ```
    /// field 1: int32 code
    /// field 2: string message
    /// ```
    ///
    /// SwiftProtobuf の生成型を持ち込むほどのものではないので、手で解く。
    static func parseRpcStatus(_ data: Data) -> (code: Int, message: String)? {
        var code: Int?
        var message = ""
        let bytes = [UInt8](data)
        var index = 0

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let tag = readVarint() else { break }
            let field = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            switch (field, wireType) {
            case (1, 0):
                guard let value = readVarint() else { return nil }
                code = Int(Int32(truncatingIfNeeded: Int64(bitPattern: value)))
            case (2, 2):
                guard let length = readVarint() else { return nil }
                let end = index + Int(length)
                guard end <= bytes.count else { return nil }
                message = String(decoding: bytes[index..<end], as: UTF8.self)
                index = end
            case (_, 0):
                _ = readVarint()
            case (_, 2):
                guard let length = readVarint() else { return nil }
                index += Int(length)
            default:
                return nil
            }
        }

        guard let code else { return nil }
        return (code, message)
    }

    // MARK: - フレーム

    /// `[フラグ 1B][長さ 4B BE][本体]` を順に取り出す。
    ///
    /// フラグの最上位ビットが立っているものは trailer フレーム。
    static func frames(in data: Data) -> [(flag: UInt8, body: Data)] {
        var out: [(flag: UInt8, body: Data)] = []
        let bytes = [UInt8](data)
        var index = 0
        while index + 5 <= bytes.count {
            let flag = bytes[index]
            var length: UInt32 = 0
            for offset in 1...4 {
                length = (length << 8) | UInt32(bytes[index + offset])
            }
            let start = index + 5
            let end = start + Int(length)
            guard end <= bytes.count else { break }
            out.append((flag, Data(bytes[start..<end])))
            index = end
        }
        return out
    }

    /// trailer フレームの中身は HTTP ヘッダと同じ書式。
    static func parseTrailer(_ body: Data) -> [String: String] {
        guard let text = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private func logResponseHeaders(_ http: HTTPURLResponse) {
        for (key, value) in http.allHeaderFields {
            let name = String(describing: key).lowercased()
            if name.hasPrefix("grpc-") || name == "content-type"
                || name == "www-authenticate" || name == "x-goog-api-explorer" {
                qlog(.info, "Account gRPC:   \(key): \(value)")
            }
        }
    }
}
