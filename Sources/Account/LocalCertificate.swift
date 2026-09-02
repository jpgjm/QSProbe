//
//  LocalCertificate.swift
//  QSProbe — 実験機能 / アカウント連携 (第5段)
//
//  **自分の証明書**を作る層。ここまでは受け取った証明書を読むだけだった。
//
//  ## 出典
//
//  すべて `github.com/google/nearby` の実装に合わせてある。
//  `sharing/certificates/nearby_share_private_certificate.cc` と
//  `sharing/certificates/constants.h`。
//
//  ```
//  secret_key              32 バイト乱数
//  secret_id               SHA-256(secret_key)          ← 乱数ではない
//  metadata_encryption_key 14 バイト乱数
//  鍵ペア                   P-256
//  有効期間                 72 時間
//  境界のぼかし             開始・終了をそれぞれ最大 2 時間ずらす
//  ```
//
//  境界をずらすのは、いつ作ったかを隠すため。上流は
//  `GenerateRandomOffset()` で ±2 時間の範囲を取る。
//
//  ## この段では Google に何も送らない
//
//  作るだけ。`PublishDevice` は次の段。
//  作ったものが正しいかは、**既に動いている読み取り側にかけて確かめる**。
//  metadata が開けて tag が合えば、鍵の組み立ては正しい。
//

import Foundation
import CryptoKit
import Security
import SwiftProtobuf

/// 端末が持つ秘密の証明書。
///
/// 公開証明書 (`NearbyPublicCertificate`) との違いは、秘密鍵を持つこと。
struct LocalCertificate: Codable {

    /// P-256 の秘密鍵 (raw representation, 32 バイト)。
    let privateKeyRaw: Data
    /// 32 バイト。これが AES 鍵にも secret_id の元にもなる。
    let secretKey: Data
    /// 14 バイト。
    let metadataEncryptionKey: Data
    /// `SHA-256(secret_key)`。
    let secretId: Data
    /// 有効期間の開始・終了 (秒)。
    let startTime: Int64
    let endTime: Int64
    /// 自分の端末向けか (`for_self_share`)。連絡先向けなら false。
    let forSelfShare: Bool
    /// 証明書に埋める端末名。
    let deviceName: String

    // MARK: - 生成

    /// 新しい証明書を作る。
    ///
    /// - Parameters:
    ///   - deviceName: 相手に見せる端末名。
    ///   - forSelfShare: 自分の端末向けか。
    ///   - now: 有効期間の起点。試験しやすいよう外から渡せる。
    static func generate(
        deviceName: String, forSelfShare: Bool, now: Date = Date()
    ) -> LocalCertificate {
        let privateKey = P256.Signing.PrivateKey()
        let secretKey = randomBytes(32)

        // 境界をぼかす。いつ作ったかを隠すための処理で、上流と同じ幅にしてある。
        let maxOffset: TimeInterval = 2 * 60 * 60
        let notBefore = now.addingTimeInterval(-TimeInterval.random(in: 0...maxOffset))
        let notAfter = now
            .addingTimeInterval(72 * 60 * 60)
            .addingTimeInterval(TimeInterval.random(in: 0...maxOffset))

        return LocalCertificate(
            privateKeyRaw: privateKey.rawRepresentation,
            secretKey: secretKey,
            metadataEncryptionKey: randomBytes(14),
            secretId: Data(SHA256.hash(data: secretKey)),
            startTime: Int64(notBefore.timeIntervalSince1970),
            endTime: Int64(notAfter.timeIntervalSince1970),
            forSelfShare: forSelfShare,
            deviceName: deviceName
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in 0..<count { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    // MARK: - 導出

    var privateKey: P256.Signing.PrivateKey? {
        try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    /// X.509 SubjectPublicKeyInfo (91 バイト)。証明書に載せる形。
    var publicKeySPKI: Data {
        privateKey?.publicKey.derRepresentation ?? Data()
    }

    var isCurrentlyValid: Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return now >= startTime && now < endTime
    }

    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }

    /// 期限が近いか。
    ///
    /// 証明書は 72 時間 × 3 枚で 9 日ぶんあるが、切れると**静かに名乗れなくなる**。
    /// 相手からは「登録済みなのに検証できない端末」に見えて接続を切られるので、
    /// 気付ける余裕を持って知らせる。
    var expiresSoon: Bool {
        endDate.timeIntervalSinceNow < 24 * 60 * 60
    }

    // MARK: - 公開証明書への変換

    /// `PublishDevice` に載せる形に変換する。
    ///
    /// 秘密鍵は入らない。metadata は暗号化して入る。
    func toPublicCertificate() -> NearbyPublicCertificate? {
        var metadata = NearbyEncryptedMetadata()
        metadata.deviceName = deviceName

        guard let plain = try? metadata.serializedData(),
              let encrypted = CertificateMetadata.encryptPayload(
                plain,
                metadataEncryptionKey: metadataEncryptionKey,
                secretKey: secretKey
              ) else {
            return nil
        }

        var certificate = NearbyPublicCertificate()
        certificate.secretId = secretId
        certificate.secretKey = secretKey
        certificate.publicKey = publicKeySPKI
        certificate.startTime = timestamp(startTime)
        certificate.endTime = timestamp(endTime)
        certificate.metadataEncryptionKey = metadataEncryptionKey
        certificate.encryptedMetadataBytes = encrypted
        certificate.metadataEncryptionKeyTag =
            CertificateMetadata.computeTag(metadataEncryptionKey)
        certificate.forSelfShare = forSelfShare
        return certificate
    }

    private func timestamp(_ seconds: Int64) -> SwiftProtobuf.Google_Protobuf_Timestamp {
        var stamp = SwiftProtobuf.Google_Protobuf_Timestamp()
        stamp.seconds = seconds
        return stamp
    }

    // MARK: - 広告

    /// 広告に載せる 16 バイト (salt 2 + 暗号化された metadata 鍵 14) を作る。
    ///
    /// 相手はこれを自分の持つ証明書の `secret_key` で復号し、
    /// tag と突き合わせて持ち主を特定する。こちらが受信時にやっていることの逆。
    ///
    /// salt は毎回変える。同じ salt を使い回すと、同じ 16 バイトが出続けて
    /// 端末を追跡されるため。
    func advertisementMetadata() -> Data? {
        let salt = Self.randomBytes(2)
        guard let encrypted = CertificateMetadata.ctr(
            metadataEncryptionKey, secretKey: secretKey, salt: salt
        ) else { return nil }
        return salt + encrypted
    }

    // MARK: - 署名

    /// `PAIRED_KEY_ENCRYPTION` に載せる署名を作る。
    ///
    /// - Parameter isSender: 自分が送信側か。印が変わる
    ///   (送信側 `0x01` / 受信側 `0x02`)。
    func sign(authToken: Data, isSender: Bool) -> Data? {
        guard let privateKey, !authToken.isEmpty else { return nil }
        let prefix = isSender
            ? PairedKeyVerifier.senderPrefix
            : PairedKeyVerifier.receiverPrefix
        let payload = Data([prefix]) + authToken
        return try? privateKey.signature(for: payload).derRepresentation
    }

    /// `secret_id_hash` は**相手の証明書**の鍵で作る値なので、
    /// 自分の証明書からは作れない。`CertificateStore.authenticationTokenHash`
    /// に相手の `secret_key` を渡すこと。
}

// MARK: - 保管

@MainActor
final class LocalCertificateStore: ObservableObject {

    static let shared = LocalCertificateStore()

    /// 可視性ごとに 3 枚ずつ、計 6 枚。
    ///
    /// 上流も同じ持ち方をしている。1 枚だけだと期限が切れた瞬間に
    /// 名乗れなくなるので、期間が連鎖するように並べて先に作っておく。
    static let perVisibilityCount = 3

    @Published private(set) var certificates: [LocalCertificate] = []
    /// 自己検証の結果。作ったものが読み取り側で通るかを確かめた記録。
    @Published private(set) var selfCheck: [String] = []

    /// 端末側で決める 10 文字の識別子。`devices/{deviceId}` に使う。
    @Published private(set) var deviceId: String

    /// 広告を証明書ベースに切り替えるか。
    ///
    /// 登録が済んでいれば常にオンでよい。オフだと相手がこちらを特定できず、
    /// 「署名は本物なのにどの証明書か分からない」相手になってしまう。
    /// 画面には出さず、登録に成功した時点で自動でオンにする。
    @Published private(set) var useForAdvertisement: Bool {
        didSet { defaults.set(useForAdvertisement, forKey: Keys.useForAdvertisement) }
    }

    /// 広告で端末名を隠すか。
    @Published var hideNameInAdvertisement: Bool {
        didSet { defaults.set(hideNameInAdvertisement, forKey: Keys.hideName) }
    }

    /// いま広告と署名に使う証明書。
    ///
    /// 自分の端末向け (`for_self_share`) で、有効期間に入っているものの先頭。
    var active: LocalCertificate? {
        certificates.first { $0.forSelfShare && $0.isCurrentlyValid }
    }

    /// 期限が切れている枚数。
    var expiredCount: Int {
        certificates.filter { !$0.isCurrentlyValid }.count
    }

    private enum Keys {
        static let useForAdvertisement = "QSProbe.account.useCertForAdvertisement"
        static let hideName = "QSProbe.account.hideNameInAdvertisement"
        static let deviceId = "QSProbe.account.deviceId"
    }

    private let defaults = UserDefaults.standard

    private init() {
        useForAdvertisement = defaults.bool(forKey: Keys.useForAdvertisement)
        hideNameInAdvertisement = defaults.bool(forKey: Keys.hideName)

        if let stored = defaults.string(forKey: Keys.deviceId), stored.count == 10 {
            deviceId = stored
        } else {
            deviceId = Self.generateDeviceId()
            defaults.set(deviceId, forKey: Keys.deviceId)
        }

        certificates = Self.load()
        if !certificates.isEmpty {
            qlog(.info, "Account 自証明書: 保存済みの \(certificates.count) 枚を読み込みました")
        }
    }

    /// 上流と同じ作り方。10 文字の `A-Z0-9`。
    ///
    /// アカウント内で端末を区別できればよく、世界で一意である必要は無い。
    private static func generateDeviceId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<10).map { _ in alphabet.randomElement() ?? "A" })
    }

    /// 登録が済んだので、広告を証明書ベースに切り替える。
    func markPublished() {
        guard !useForAdvertisement else { return }
        useForAdvertisement = true
        qlog(.ok, "Account 自証明書: 広告を証明書ベースに切り替えました")
    }

    /// 残り時間を人が読む形にする。
    static func remainingText(_ certificate: LocalCertificate) -> String {
        let remaining = certificate.endDate.timeIntervalSinceNow
        guard remaining > 0 else { return "期限切れ" }
        let days = Int(remaining / (24 * 60 * 60))
        if days >= 1 { return "あと \(days) 日" }
        let hours = Int(remaining / 3600)
        return hours >= 1 ? "あと \(hours) 時間" : "まもなく期限切れ"
    }

    // MARK: - 生成

    /// 可視性ごとに 3 枚ずつ作る。
    ///
    /// 期間は連鎖させる。1 枚目が今から 72 時間、2 枚目はその終わりから
    /// 72 時間、という並べ方。こうしておくと 9 日ぶんの有効期間が先に埋まる。
    func generate(deviceName: String) {
        var created: [LocalCertificate] = []

        for forSelf in [true, false] {
            var start = Date()
            for _ in 0..<Self.perVisibilityCount {
                let certificate = LocalCertificate.generate(
                    deviceName: deviceName, forSelfShare: forSelf, now: start
                )
                created.append(certificate)
                start = certificate.endDate
            }
        }

        certificates = created
        Self.save(created)

        qlog(.ok, "Account 自証明書: ★ \(created.count) 枚を作成しました")
        qlog(.info, "Account 自証明書:   device_id = \(deviceId)")
        for certificate in created {
            qlog(.info, "Account 自証明書:   "
                + "\(certificate.forSelfShare ? "自分" : "連絡先") / "
                + "\(CertificateStore.hex(certificate.secretId, limit: 6)) / "
                + "〜\(Self.format(certificate.endDate))")
        }

        runSelfCheck()
    }

    func clear() {
        certificates = []
        selfCheck = []
        Self.deleteStored()
        qlog(.info, "Account 自証明書: 消しました")
    }

    // MARK: - 自己検証

    /// 作った証明書を、**受信側の処理にそのままかけて**確かめる。
    ///
    /// 読み取り側は実測で正しさが確認できているので、そこを通れば
    /// 組み立ても正しいと言える。Google に何も送らずに検算できる。
    func runSelfCheck() {
        guard let certificate = active ?? certificates.first else {
            selfCheck = []
            return
        }
        var results: [String] = []

        guard let published = certificate.toPublicCertificate() else {
            selfCheck = ["公開証明書に変換できませんでした"]
            qlog(.error, "Account 自証明書: ✗ 公開証明書に変換できません")
            return
        }

        results.append("tag の検算: "
            + (CertificateMetadata.tagMatches(published) ? "一致" : "不一致"))

        if let metadata = CertificateMetadata.decrypt(published) {
            results.append("metadata: \(metadata.summary)")
        } else {
            results.append("metadata: 開けません")
        }

        if let advertisement = certificate.advertisementMetadata(),
           let match = AdvertisementIdentity.identify(
            metadata: advertisement, certificates: [published]
           ) {
            let same = match.certificate.secretId == published.secretId
            results.append("広告からの特定: \(same ? "成功" : "別の証明書に当たった")")
        } else {
            results.append("広告からの特定: 失敗")
        }

        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        if let signature = certificate.sign(authToken: token, isSender: true),
           PairedKeyVerifier.verify(
            signature: signature,
            publicKeySPKI: published.publicKey,
            authToken: token
           ) != nil {
            results.append("署名の検証: 成功")
        } else {
            results.append("署名の検証: 失敗")
        }

        selfCheck = results
        qlog(.info, "Account 自証明書: --- 自己検証 ---")
        for line in results {
            let ok = !line.contains("失敗") && !line.contains("不一致")
                && !line.contains("開けません")
            qlog(ok ? .ok : .error, "Account 自証明書:   \(line)")
        }
        qlog(.info, "Account 自証明書: ----------------")
    }

    // MARK: - 保存

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalCertificates.json")
    }

    private static func save(_ certificates: [LocalCertificate]) {
        guard let fileURL,
              let data = try? JSONEncoder().encode(certificates) else { return }
        do {
            // 秘密鍵が入るので、端末のロック中は読めないようにする。
            try data.write(to: fileURL, options: [.completeFileProtection])
        } catch {
            qlog(.warn, "Account 自証明書: 保存に失敗 — \(error.localizedDescription)")
        }
    }

    private static func load() -> [LocalCertificate] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LocalCertificate].self, from: data)) ?? []
    }

    private static func deleteStored() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }
}
