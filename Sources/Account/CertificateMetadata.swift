//
//  CertificateMetadata.swift
//  QSProbe — 実験機能 / アカウント連携
//
//  証明書まわりの暗号処理。**すべて上流の実装に合わせてある。**
//
//  ## 出典
//
//  `nearby_share.exe` に埋まっていたソースパスが
//  `third_party/nearby/sharing/certificates/…` だったことから、
//  実装が Google のオープンソース (github.com/google/nearby) にあると分かった。
//  以下はそこから読み取ったもので、推測は含まない。
//
//  - `sharing/certificates/common.cc`
//  - `sharing/certificates/nearby_share_private_certificate.cc`
//  - `sharing/certificates/nearby_share_decrypted_public_certificate.cc`
//  - `sharing/certificates/constants.h`
//
//  ## 3 つの導出
//
//  すべての土台は `DeriveNearbyShareKey`。
//
//  ```
//  DeriveNearbyShareKey(key, n) = HKDF-SHA256(ikm: key, salt: 空, info: 空, n)
//  ```
//
//  **① 広告に載る metadata 鍵 (AES-256-CTR)**
//
//  ```
//  鍵     = secret_key をそのまま (導出しない)
//  カウンタ = DeriveNearbyShareKey(salt, 16)
//  ```
//
//  **② metadata 本体 (AES-256-GCM)**
//
//  ```
//  鍵    = DeriveNearbyShareKey(metadata_encryption_key, 32)
//  nonce = DeriveNearbyShareKey(secret_key, 12)      ← secret_key から
//  AAD   = 空
//  ```
//
//  nonce が `secret_key` 由来である点が肝で、ここを取り違えると開かない。
//
//  **③ metadata 鍵の検算**
//
//  ```
//  tag = HMAC-SHA256(鍵: 32 バイトのゼロ, メッセージ: metadata_encryption_key)
//  ```
//
//  上流のコメントには「GmsCore の実装に合わせるためのゼロ配列」とある。
//

import Foundation
import CryptoKit
import CommonCrypto
import SwiftProtobuf

enum CertificateMetadata {

    /// `DeriveNearbyShareKey`。HKDF-SHA256、salt と info は空。
    static func derive(_ key: Data, length: Int) -> Data {
        guard !key.isEmpty else { return Data() }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(),
            info: Data(),
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - metadata 鍵の検算

    /// `tag == HMAC-SHA256(ゼロ 32 バイト, metadata_encryption_key)` か。
    static func tagMatches(_ certificate: NearbyPublicCertificate) -> Bool {
        guard !certificate.metadataEncryptionKey.isEmpty,
              certificate.metadataEncryptionKeyTag.count == 32 else { return false }
        return computeTag(certificate.metadataEncryptionKey)
            == certificate.metadataEncryptionKeyTag
    }

    /// metadata 鍵から tag を作る。復号した鍵の検算にも使う。
    static func computeTag(_ metadataEncryptionKey: Data) -> Data {
        let zeroKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        return Data(HMAC<SHA256>.authenticationCode(
            for: metadataEncryptionKey, using: zeroKey
        ))
    }

    // MARK: - metadata 本体

    /// `encrypted_metadata_bytes` を開く。
    ///
    /// AES-256-GCM なので、鍵か nonce が違えば認証タグが合わずに失敗する。
    /// **開けたこと自体が正しさの証明**になるので、中身の妥当性を別途
    /// 見る必要はない。
    static func decrypt(
        _ certificate: NearbyPublicCertificate
    ) -> NearbyEncryptedMetadata? {
        let plain = decryptPayload(
            certificate.encryptedMetadataBytes,
            metadataEncryptionKey: certificate.metadataEncryptionKey,
            secretKey: certificate.secretKey
        )
        guard let plain else { return nil }
        return try? NearbyEncryptedMetadata(serializedBytes: plain)
    }

    /// 復号の本体。鍵を外から与えられるようにしてある
    /// (広告から復元した metadata 鍵でも開けるように)。
    static func decryptPayload(
        _ cipher: Data, metadataEncryptionKey: Data, secretKey: Data
    ) -> Data? {
        guard cipher.count > 16, !metadataEncryptionKey.isEmpty,
              !secretKey.isEmpty else { return nil }

        let key = SymmetricKey(data: derive(metadataEncryptionKey, length: 32))
        let nonceBytes = derive(secretKey, length: 12)

        // GCM の認証タグは末尾 16 バイト。
        let tag = Data(cipher.suffix(16))
        let body = Data(cipher.dropLast(16))

        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }

    /// 逆向き。自分の証明書を作るときに使う (第 5 段)。
    static func encryptPayload(
        _ plain: Data, metadataEncryptionKey: Data, secretKey: Data
    ) -> Data? {
        let key = SymmetricKey(data: derive(metadataEncryptionKey, length: 32))
        let nonceBytes = derive(secretKey, length: 12)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce)
            return box.ciphertext + box.tag
        } catch {
            return nil
        }
    }

    // MARK: - AES-CTR (広告の metadata 鍵)

    /// `CreateNearbyShareCtrEncryptor` に相当。
    ///
    /// **鍵は secret_key をそのまま使う。** 導出しない。
    /// カウンタだけ salt から導出する。
    static func ctr(_ input: Data, secretKey: Data, salt: Data) -> Data? {
        guard secretKey.count == 32, salt.count == 2 else { return nil }
        return aesCTR(input, key: secretKey, counter: derive(salt, length: 16))
    }

    /// AES-CTR。CryptoKit に CTR が無いので CommonCrypto を使う。
    /// CTR は対称なので、復号も暗号化と同じ操作でよい。
    private static func aesCTR(_ input: Data, key: Data, counter: Data) -> Data? {
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count),
              counter.count == kCCBlockSizeAES128 else {
            return nil
        }

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            counter.withUnsafeBytes { counterBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    counterBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        // 可変借用の中で `output.count` を読むと排他アクセスに反するので、
        // 長さは借用の外で控える。
        let capacity = input.count + kCCBlockSizeAES128
        let inputCount = input.count
        var output = Data(count: capacity)
        var moved = 0

        let updateStatus = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress, inputCount,
                    outputBytes.baseAddress, outputBytes.count,
                    &moved
                )
            }
        }
        guard updateStatus == CCCryptorStatus(kCCSuccess) else { return nil }
        return output.prefix(moved)
    }
}

// MARK: - 広告からの特定

/// 相手の EndpointInfo に載っている 16 バイト (salt 2 + 暗号化された
/// metadata 鍵 14) から、どの証明書の持ち主かを割り出す。
///
/// 上流の `NearbyShareDecryptedPublicCertificate::DecryptPublicCertificate`
/// と同じ手順。
///
/// ```
/// 復号した鍵 = AES-256-CTR(鍵: secret_key, カウンタ: HKDF(salt, 16))
/// 検算       = HMAC-SHA256(ゼロ, 復号した鍵) == metadata_encryption_key_tag
/// ```
///
/// 検算があるので、当たりに疑いの余地が無い。
enum AdvertisementIdentity {

    struct Match {
        let certificate: NearbyPublicCertificate
        /// 復号できた metadata 鍵 (14 バイト)。
        let metadataKey: Data
    }

    static func identify(
        metadata: Data, certificates: [NearbyPublicCertificate]
    ) -> Match? {
        guard metadata.count >= 16 else { return nil }
        let salt = Data(metadata.prefix(2))
        let encrypted = Data(metadata.dropFirst(2).prefix(14))

        for certificate in certificates {
            guard certificate.metadataEncryptionKeyTag.count == 32,
                  certificate.secretKey.count == 32 else { continue }
            guard let decrypted = CertificateMetadata.ctr(
                encrypted, secretKey: certificate.secretKey, salt: salt
            ) else { continue }

            if CertificateMetadata.computeTag(decrypted)
                == certificate.metadataEncryptionKeyTag {
                return Match(certificate: certificate, metadataKey: decrypted)
            }
        }
        return nil
    }
}

// MARK: - EncryptedMetadata

/// `nearby.sharing.proto.EncryptedMetadata`。
///
/// フィールド番号は `sharing/proto/encrypted_metadata.proto` のとおり。
/// 以前は 5 と 6 を取り違えていた。
struct NearbyEncryptedMetadata: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "nearby.sharing.proto.EncryptedMetadata"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// 証明書を作った時点の端末名。
    var deviceName = ""
    /// 証明書を作った端末の持ち主の氏名。
    var fullName = ""
    var iconURL = ""
    var bluetoothMacAddress = Data()
    /// 難読化された Gaia ID。
    var obfuscatedGaiaId = ""
    var accountName = ""
    var modelName = ""

    var summary: String {
        var parts: [String] = []
        if !deviceName.isEmpty { parts.append(deviceName) }
        if !modelName.isEmpty, modelName != deviceName { parts.append(modelName) }
        if !accountName.isEmpty { parts.append(accountName) }
        else if !fullName.isEmpty { parts.append(fullName) }
        return parts.isEmpty ? "(名前なし)" : parts.joined(separator: " / ")
    }

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &deviceName)
            case 2: try decoder.decodeSingularStringField(value: &fullName)
            case 3: try decoder.decodeSingularStringField(value: &iconURL)
            case 4: try decoder.decodeSingularBytesField(value: &bluetoothMacAddress)
            case 5: try decoder.decodeSingularStringField(value: &obfuscatedGaiaId)
            case 6: try decoder.decodeSingularStringField(value: &accountName)
            case 7: try decoder.decodeSingularStringField(value: &modelName)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !deviceName.isEmpty {
            try visitor.visitSingularStringField(value: deviceName, fieldNumber: 1)
        }
        if !fullName.isEmpty {
            try visitor.visitSingularStringField(value: fullName, fieldNumber: 2)
        }
        if !iconURL.isEmpty {
            try visitor.visitSingularStringField(value: iconURL, fieldNumber: 3)
        }
        if !bluetoothMacAddress.isEmpty {
            try visitor.visitSingularBytesField(value: bluetoothMacAddress, fieldNumber: 4)
        }
        if !obfuscatedGaiaId.isEmpty {
            try visitor.visitSingularStringField(value: obfuscatedGaiaId, fieldNumber: 5)
        }
        if !accountName.isEmpty {
            try visitor.visitSingularStringField(value: accountName, fieldNumber: 6)
        }
        if !modelName.isEmpty {
            try visitor.visitSingularStringField(value: modelName, fieldNumber: 7)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyEncryptedMetadata else { return false }
        return deviceName == other.deviceName && accountName == other.accountName
    }
}
