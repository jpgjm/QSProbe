//
//  CertificateStore.swift
//  QSProbe — 実験機能 / アカウント連携 (第3段)
//
//  `QuerySharedCredentials` で取れた公開証明書を持っておく層。
//
//  ## なぜ持つのか
//
//  受信時、相手は `PAIRED_KEY_ENCRYPTION` に `secret_id_hash` を載せてくる。
//  これは相手が使っている証明書の識別子で、こちらが同じ証明書を持っていれば
//  「その相手が誰か」を照合できる。いまは持っていないので
//  `PAIRED_KEY_RESULT = unable` を返すしかない。
//
//  ## 保存先
//
//  `Documents/AccountCertificates/` に生の protobuf をそのまま置く。
//  JSON に詰め直すと、あとで別の解釈をしたくなったときに情報が落ちる。
//
//  アンインストールで消えるが、再取得は 1 タップなので困らない。
//
//  ## secret_id_hash の作り方は未確定
//
//  相手が送ってくるのは 6 バイト。`secret_id` は 32 バイト。
//  間に何の変換が挟まるかは実測で当てるしかないので、候補をいくつか計算して
//  全部持っておき、どれが一致したかをログに出す。
//

import Foundation
import CryptoKit
import SwiftProtobuf

/// 1 件の証明書と、そこから引ける識別子。
struct StoredCertificate {

    /// `SharedCredential.id`。サーバ側の識別子。
    let credentialId: Int64

    /// 復元した `PublicCertificate`。
    let certificate: NearbyPublicCertificate

    /// 元の protobuf バイト列。解釈をやり直したいとき用に取っておく。
    let raw: Data

    init(credentialId: Int64, certificate: NearbyPublicCertificate, raw: Data) {
        self.credentialId = credentialId
        self.certificate = certificate
        self.raw = raw
        self.metadata = CertificateMetadata.decrypt(certificate)
    }

    var secretId: Data { certificate.secretId }

    /// `wire_format.proto` の `authenticity_key` (フィールド 2)。
    ///
    /// RPC 側の `PublicCertificate` では同じフィールドが `secret_key` と
    /// 呼ばれている。名前が違うだけで同じもの。
    var secretKey: Data { certificate.secretKey }

    /// `tag == HMAC-SHA256(ゼロ, metadata_key)` か。上流の実装どおりなら必ず真。
    var tagMatches: Bool { CertificateMetadata.tagMatches(certificate) }

    /// 復号できた metadata。誰の証明書かが分かる。
    ///
    /// AES-GCM なので、開けたこと自体が鍵の正しさの証明になる。
    /// 生成時に一度だけ解いて持つ。計算プロパティにすると
    /// 画面の再描画のたびに走ってしまう。
    let metadata: NearbyEncryptedMetadata?

    /// どのフィールドが入っているかの一覧。診断用。
    ///
    /// 欠けているフィールドがあれば、証明書の形がこちらの定義とずれている。
    var fieldCensus: [String: Int] {
        [
            "secret_id": certificate.secretId.count,
            "secret_key": certificate.secretKey.count,
            "public_key": certificate.publicKey.count,
            "metadata_key": certificate.metadataEncryptionKey.count,
            "encrypted_metadata": certificate.encryptedMetadataBytes.count,
            "metadata_key_tag": certificate.metadataEncryptionKeyTag.count,
            "binding_id": certificate.bindingId.count,
            "extra_blob": certificate.extraBlob.count,
        ]
    }

    /// `secret_id_hash` を計算する。
    ///
    /// 上流の `ComputeAuthenticationTokenHash` そのもの。
    ///
    /// ```
    /// HKDF-SHA256(ikm: 認証トークン, salt: secret_key, info: 空, 6 バイト)
    /// ```
    ///
    /// 名前に反して証明書の識別子ではなく、**接続ごとの認証トークンを
    /// 証明書の鍵で潰したもの**。接続のたびに値が変わるのはそのため。
    func authenticationTokenHash(_ token: Data) -> Data {
        CertificateStore.authenticationTokenHash(token: token, secretKey: secretKey)
    }

    var startDate: Date? {
        certificate.startTime.map { Date(timeIntervalSince1970: TimeInterval($0.seconds)) }
    }

    var endDate: Date? {
        certificate.endTime.map { Date(timeIntervalSince1970: TimeInterval($0.seconds)) }
    }

    /// いま有効な期間に入っているか。
    var isCurrentlyValid: Bool {
        let now = Date()
        if let startDate, now < startDate { return false }
        if let endDate, now > endDate { return false }
        return true
    }

    var summary: String {
        let idHex = CertificateStore.hex(secretId, limit: 8)
        var parts: [String] = []
        if let name = metadata?.summary { parts.append(name) }
        parts.append("secret_id=\(idHex)")
        parts.append(certificate.forSelfShare ? "自分の端末" : "連絡先")
        parts.append("metadata \(certificate.encryptedMetadataBytes.count)B")
        if let endDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            parts.append("〜\(formatter.string(from: endDate))")
        }
        if !isCurrentlyValid { parts.append("期限外") }
        return parts.joined(separator: " / ")
    }
}

@MainActor
final class CertificateStore: ObservableObject {

    static let shared = CertificateStore()

    @Published private(set) var certificates: [StoredCertificate] = []
    @Published private(set) var lastUpdated: Date?
    /// 復元できなかった件数。`data` が `PublicCertificate` でない証拠になる。
    @Published private(set) var undecodableCount = 0

    private init() {
        loadFromDisk()
    }

    // MARK: - 取り込み

    /// `QuerySharedCredentials` の結果を取り込む。
    ///
    /// - Returns: 復元できた件数。
    @discardableResult
    func ingest(_ credentials: [NearbySharedCredential]) -> Int {
        var decoded: [StoredCertificate] = []
        var failures = 0

        for credential in credentials {
            // 公開証明書だけを見る。他の data_type は用途が違う。
            guard credential.dataType == 1 else { continue }
            do {
                let certificate = try NearbyPublicCertificate(serializedBytes: credential.data)
                decoded.append(StoredCertificate(
                    credentialId: credential.id,
                    certificate: certificate,
                    raw: credential.data
                ))
            } catch {
                failures += 1
                qlog(.warn, "Account 証明書: id=\(credential.id) を復元できません — \(error)")
            }
        }

        certificates = decoded
        undecodableCount = failures
        lastUpdated = Date()

        qlog(.ok, "Account 証明書: \(decoded.count) 件を保持しました "
            + "(復元できず \(failures) 件)")

        let valid = decoded.filter { $0.isCurrentlyValid }.count
        qlog(.info, "Account 証明書:   いま有効なもの = \(valid) 件")

        // 鍵が入っていなければ、鍵を使う導出は最初から成立しない。
        // 総当たりを増やす前に、材料の有無を確かめる。
        logFieldCensus(decoded)

        // 定義を持たないまま生の構造を出す。定義を直したあとも、
        // 取りこぼしが無いかの確認に使える。
        logRawStructure(decoded)

        // 証明書が誰のものかを出す。ここが出れば、照合できない理由を
        // 「相手が証明書を使っていない」に絞り込める。
        logOwners(decoded)

        saveToDisk()
        return decoded.count
    }

    /// どのフィールドがどれだけ埋まっているかを数える。
    ///
    /// 空のフィールドが分かれば、試すまでもない候補を落とせる。
    private func logFieldCensus(_ stored: [StoredCertificate]) {
        guard !stored.isEmpty else { return }
        var present: [String: Int] = [:]
        var sizes: [String: Set<Int>] = [:]

        for item in stored {
            for (field, count) in item.fieldCensus {
                if count > 0 {
                    present[field, default: 0] += 1
                    sizes[field, default: []].insert(count)
                }
            }
        }

        qlog(.info, "Account 証明書:   --- フィールドの中身 ---")
        for field in ["secret_id", "secret_key", "public_key", "metadata_key",
                      "encrypted_metadata", "metadata_key_tag", "extra_blob",
                      "binding_id"] {
            let count = present[field] ?? 0
            let lengths = (sizes[field] ?? []).sorted()
                .map(String.init).joined(separator: "/")
            let level: LogLevel = count == 0 ? .warn : .info
            qlog(level, "Account 証明書:     \(field) = \(count)/\(stored.count) 件"
                + (lengths.isEmpty ? "" : " (\(lengths) バイト)"))
        }
        if (present["secret_key"] ?? 0) == 0 {
            qlog(.warn, "Account 証明書:   ⚠ secret_key が空です。"
                + "鍵を使う導出は成立しません")
        }
        qlog(.info, "Account 証明書:   ----------------------")
    }

    /// `data` の生の構造を出す。長さの種類ごとに 1 件ずつ。
    ///
    /// Bada の `wire_format.proto` で読めるのは 180 バイト程度なのに、
    /// 実際は 394〜1037 バイトある。**残りが何なのかを、推測ではなく
    /// バイト列から出す。**
    private func logRawStructure(_ stored: [StoredCertificate]) {
        // 同じ長さのものを何件も出しても仕方がないので、長さごとに 1 件。
        var seenSizes = Set<Int>()
        var samples: [StoredCertificate] = []
        for item in stored where seenSizes.insert(item.raw.count).inserted {
            samples.append(item)
        }

        qlog(.info, "Account 証明書:   --- 生の構造 (長さの種類ごとに 1 件) ---")
        for sample in samples.prefix(4) {
            qlog(.info, "Account 証明書:   [id=\(sample.credentialId)]")
            for line in ProtoInspector.describe(sample.raw) {
                qlog(.info, "Account 証明書:   \(line)")
            }
            // f11 は中身の定義が未確定なので、一段だけ掘って構造を出す。
            if !sample.certificate.extraBlob.isEmpty {
                qlog(.info, "Account 証明書:     f11 の中身:")
                for line in ProtoInspector.describe(sample.certificate.extraBlob) {
                    qlog(.info, "Account 証明書:     \(line)")
                }
            }
        }
        qlog(.info, "Account 証明書:   --------------------------------------")
    }

    /// tag の検算と、metadata の復号結果を出す。
    ///
    /// どちらも上流の実装どおりなら全件そろうはず。欠けるなら、
    /// 証明書の形かこちらの実装のどちらかがずれている。
    private func logOwners(_ stored: [StoredCertificate]) {
        guard !stored.isEmpty else { return }

        let tagOK = stored.filter { $0.tagMatches }.count
        qlog(tagOK == stored.count ? .ok : .warn,
             "Account 証明書:   tag の検算: \(tagOK)/\(stored.count) 件が一致")

        let opened = stored.compactMap { $0.metadata }
        if opened.isEmpty {
            qlog(.warn, "Account 証明書:   metadata を 1 件も開けませんでした")
            return
        }

        qlog(.ok, "Account 証明書:   ★★ \(opened.count)/\(stored.count) 件の metadata を開けました")
        qlog(.info, "Account 証明書:   --- 証明書の持ち主 ---")

        var names: [String: Int] = [:]
        for metadata in opened {
            names[metadata.summary, default: 0] += 1
        }
        for (name, count) in names.sorted(by: { $0.value > $1.value }) {
            qlog(.ok, "Account 証明書:     \(name) — \(count) 件")
        }
        qlog(.info, "Account 証明書:   ----------------------")
    }

    // MARK: - 照合

    /// 相手が送ってきた `secret_id_hash` に一致する証明書を探す。
    ///
    /// 計算式は確定しているので、総当たりはしない。
    func match(secretIdHash: Data, authToken: Data?) -> StoredCertificate? {
        guard !secretIdHash.isEmpty, let authToken, !authToken.isEmpty else { return nil }
        return certificates.first {
            $0.authenticationTokenHash(authToken) == secretIdHash
        }
    }

    // MARK: - 保存

    private var directoryURL: URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("AccountCertificates", isDirectory: true)
    }

    private func saveToDisk() {
        guard let directoryURL else { return }
        do {
            // 古いものが残ると件数が合わなくなるので、作り直す。
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
            }
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )
            for stored in certificates {
                let url = directoryURL.appendingPathComponent("\(stored.credentialId).pb")
                try stored.raw.write(to: url)
            }
            qlog(.info, "Account 証明書: Documents/AccountCertificates/ に書き出しました")
        } catch {
            qlog(.warn, "Account 証明書: 書き出しに失敗 — \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() {
        guard let directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
              ) else { return }

        var restored: [StoredCertificate] = []
        for url in files where url.pathExtension == "pb" {
            guard let data = try? Data(contentsOf: url),
                  let certificate = try? NearbyPublicCertificate(serializedBytes: data)
            else { continue }
            let id = Int64(url.deletingPathExtension().lastPathComponent) ?? 0
            restored.append(StoredCertificate(
                credentialId: id, certificate: certificate, raw: data
            ))
        }

        guard !restored.isEmpty else { return }
        certificates = restored
        qlog(.info, "Account 証明書: 保存済みの \(restored.count) 件を読み込みました")
    }

    func clear() {
        certificates = []
        undecodableCount = 0
        lastUpdated = nil
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        qlog(.info, "Account 証明書: 保持していた証明書を消しました")
    }

    // MARK: - 表示

    /// `StoredCertificate` はメインアクターに属さない素の struct なので、
    /// そこから呼べるように `nonisolated` にしておく。
    /// 中身は純粋な変換で、共有状態には触れない。
    nonisolated static func hex(_ data: Data, limit: Int? = nil) -> String {
        let slice = limit.map { data.prefix($0) } ?? data.prefix(data.count)
        let text = slice.map { String(format: "%02x", $0) }.joined()
        if let limit, data.count > limit { return text + "…" }
        return text
    }
}


extension CertificateStore {

    /// `ComputeAuthenticationTokenHash`。
    ///
    /// ```
    /// HKDF-SHA256(ikm: 認証トークン, salt: secret_key, info: 空, 6 バイト)
    /// ```
    ///
    /// **どの証明書の鍵を使うかで意味が変わる。**
    /// 送るときは相手の証明書の鍵、受け取った値を照合するときはこちらの鍵。
    nonisolated static func authenticationTokenHash(
        token: Data, secretKey: Data
    ) -> Data {
        guard !token.isEmpty, !secretKey.isEmpty else { return Data() }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token),
            salt: secretKey,
            info: Data(),
            outputByteCount: 6
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
