//
//  NearbyIdentityProtos.swift
//  QSProbe
//
//  `google.nearby.identity.v1` の proto を **手書き**で持ったもの。
//
//  ## なぜ手書きなのか
//
//  この proto は Google の公開リポジトリに無く、`nearby_share.exe` の
//  バイナリから `FileDescriptorProto` を復号して構造を割り出した。
//  外部の `.proto` ファイルを引っ張ってくる出所が無いので、
//  必要なメッセージだけを直接 `SwiftProtobuf.Message` に準拠させる。
//
//  ## 実装しているもの (第 2 段のぶんだけ)
//
//  - `GetAccountInfoRequest`   — 空メッセージ
//  - `GetAccountInfoResponse`  — `AccountInfo account_info = 1;`
//  - `NearbyAccountInfo`       — `string current_dusi = 1; repeated int32 capabilities = 2;`
//
//  第 3 段以降 (PublishDevice / QuerySharedCredentials) は別のファイルに足す。
//  ここに詰め込むと肥大するので、ここは「疎通確認に必要なもの」だけ。
//

import Foundation
import SwiftProtobuf

// MARK: - GetAccountInfo

/// `google.nearby.identity.v1.GetAccountInfoRequest`。空メッセージ。
struct NearbyGetAccountInfoRequest: SwiftProtobuf.Message {

    static let protoMessageName = "google.nearby.identity.v1.GetAccountInfoRequest"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        // 何もない
        while let _ = try decoder.nextFieldNumber() {}
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        message is NearbyGetAccountInfoRequest
    }
}

/// `google.nearby.identity.v1.GetAccountInfoResponse`。
struct NearbyGetAccountInfoResponse: SwiftProtobuf.Message {

    static let protoMessageName = "google.nearby.identity.v1.GetAccountInfoResponse"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `account_info = 1;`
    ///
    /// SwiftProtobuf の `decodeSingularMessageField(value:)` は
    /// `inout Message?` を取るため、内部保持は Optional。
    /// 呼び出し側の使い勝手のために `accountInfo` は非 Optional として露出する。
    var accountInfo: NearbyAccountInfo {
        get { _accountInfo ?? NearbyAccountInfo() }
        set { _accountInfo = newValue }
    }
    var hasAccountInfo: Bool { _accountInfo != nil }

    private var _accountInfo: NearbyAccountInfo?

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeSingularMessageField(value: &_accountInfo)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if let inner = _accountInfo {
            try visitor.visitSingularMessageField(value: inner, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyGetAccountInfoResponse else { return false }
        return _accountInfo == other._accountInfo
    }
}

/// `google.nearby.identity.v1.AccountInfo`。
///
/// `AccountInfo` は QSProbe の別モジュールにも似た名前があるかもしれないので、
/// 衝突を避けて `Nearby` を接頭辞に付けてある。
struct NearbyAccountInfo: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "google.nearby.identity.v1.AccountInfo"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `string current_dusi = 1;`
    ///
    /// DUSI = Device User Sync Identifier (推定)。
    /// アカウント内で個々の端末を識別する文字列。stock のログにも
    /// `nearby_sharing.device_id` の pref があった。
    var currentDusi: String = ""

    /// `repeated Capability capabilities = 2;`
    ///
    /// enum は int32 で受ける。定義は次のとおり:
    ///   0 = CAPABILITY_UNSPECIFIED
    ///   1 = CAPABILITY_TITANIUM
    var capabilities: [Int32] = []

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &currentDusi)
            case 2: try decoder.decodeRepeatedInt32Field(value: &capabilities)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !currentDusi.isEmpty {
            try visitor.visitSingularStringField(value: currentDusi, fieldNumber: 1)
        }
        if !capabilities.isEmpty {
            try visitor.visitPackedInt32Field(value: capabilities, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyAccountInfo else { return false }
        return currentDusi == other.currentDusi
            && capabilities == other.capabilities
    }
}

// MARK: - GetIdentityBrokerConfig

/// `google.nearby.identity.v1.GetIdentityBrokerConfigRequest`。
///
/// `name` は資源名で、proto の `google.api.resource` 註釈が
/// `nearby.googleapis.com/IdentityBrokerConfig` と宣言している。
/// 単数資源なので `identityBrokerConfig` 固定のはず。
struct NearbyGetIdentityBrokerConfigRequest: SwiftProtobuf.Message {

    static let protoMessageName = "google.nearby.identity.v1.GetIdentityBrokerConfigRequest"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `string name = 1;`
    var name: String = ""

    init() {}

    init(name: String) {
        self.name = name
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &name)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !name.isEmpty {
            try visitor.visitSingularStringField(value: name, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyGetIdentityBrokerConfigRequest else { return false }
        return name == other.name
    }
}

/// `google.nearby.identity.v1.IdentityBrokerConfig`。
///
/// このメッセージが `GetIdentityBrokerConfig` の応答そのもの
/// (`…Response` で包まれていない)。証明書の検証に使う根の公開鍵が入る。
struct NearbyIdentityBrokerConfig: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "google.nearby.identity.v1.IdentityBrokerConfig"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `repeated bytes root_authority_public_keys = 1;`
    var rootAuthorityPublicKeys: [Data] = []

    /// `repeated bytes intermediate_authority_certificates = 2;`
    var intermediateAuthorityCertificates: [Data] = []

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeRepeatedBytesField(value: &rootAuthorityPublicKeys)
            case 2: try decoder.decodeRepeatedBytesField(
                value: &intermediateAuthorityCertificates)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !rootAuthorityPublicKeys.isEmpty {
            try visitor.visitRepeatedBytesField(
                value: rootAuthorityPublicKeys, fieldNumber: 1)
        }
        if !intermediateAuthorityCertificates.isEmpty {
            try visitor.visitRepeatedBytesField(
                value: intermediateAuthorityCertificates, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyIdentityBrokerConfig else { return false }
        return rootAuthorityPublicKeys == other.rootAuthorityPublicKeys
            && intermediateAuthorityCertificates == other.intermediateAuthorityCertificates
    }
}

// MARK: - QuerySharedCredentials

/// `google.nearby.identity.v1.QuerySharedCredentialsRequest`。
///
/// `name` は `devices/{device_id}` の形。この `device_id` の出どころは
/// まだ確定していない。`GetAccountInfo` が返す `current_dusi` が
/// そのまま使えるかどうかが、いま確かめたいこと。
struct NearbyQuerySharedCredentialsRequest: SwiftProtobuf.Message {

    static let protoMessageName =
        "google.nearby.identity.v1.QuerySharedCredentialsRequest"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `string name = 1;`
    var name: String = ""
    /// `int32 page_size = 2;`
    var pageSize: Int32 = 0
    /// `string page_token = 3;`
    var pageToken: String = ""

    init() {}

    init(name: String, pageSize: Int32 = 0, pageToken: String = "") {
        self.name = name
        self.pageSize = pageSize
        self.pageToken = pageToken
    }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &name)
            case 2: try decoder.decodeSingularInt32Field(value: &pageSize)
            case 3: try decoder.decodeSingularStringField(value: &pageToken)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !name.isEmpty {
            try visitor.visitSingularStringField(value: name, fieldNumber: 1)
        }
        if pageSize != 0 {
            try visitor.visitSingularInt32Field(value: pageSize, fieldNumber: 2)
        }
        if !pageToken.isEmpty {
            try visitor.visitSingularStringField(value: pageToken, fieldNumber: 3)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyQuerySharedCredentialsRequest else { return false }
        return name == other.name && pageSize == other.pageSize && pageToken == other.pageToken
    }
}

/// `google.nearby.identity.v1.QuerySharedCredentialsResponse`。
struct NearbyQuerySharedCredentialsResponse: SwiftProtobuf.Message {

    static let protoMessageName =
        "google.nearby.identity.v1.QuerySharedCredentialsResponse"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `repeated SharedCredential shared_credentials = 1;`
    var sharedCredentials: [NearbySharedCredential] = []
    /// `string next_page_token = 2;`
    var nextPageToken: String = ""

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeRepeatedMessageField(value: &sharedCredentials)
            case 2: try decoder.decodeSingularStringField(value: &nextPageToken)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !sharedCredentials.isEmpty {
            try visitor.visitRepeatedMessageField(value: sharedCredentials, fieldNumber: 1)
        }
        if !nextPageToken.isEmpty {
            try visitor.visitSingularStringField(value: nextPageToken, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyQuerySharedCredentialsResponse else { return false }
        return sharedCredentials == other.sharedCredentials
            && nextPageToken == other.nextPageToken
    }
}

/// `google.nearby.identity.v1.SharedCredential`。
///
/// `data_type` が `DATA_TYPE_PUBLIC_CERTIFICATE` (1) のとき、`data` は
/// Bada の `wire_format.proto` の `PublicCertificate` の protobuf バイト列
/// **のはず**。ここが第 4 段の要になる仮定で、実測で確かめる必要がある。
///
/// フィールド番号 4 は欠番。バイナリの descriptor でも 1,2,3,5 だった。
struct NearbySharedCredential: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "google.nearby.identity.v1.SharedCredential"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `int64 id = 1;`
    var id: Int64 = 0
    /// `DataType data_type = 2;` (0=未指定, 1=公開証明書, 2=共有資格情報)
    var dataType: Int32 = 0
    /// `bytes data = 3;`
    var data: Data = Data()
    /// `google.protobuf.Timestamp expiration_time = 5;`
    var expirationTime: SwiftProtobuf.Google_Protobuf_Timestamp?

    var dataTypeLabel: String {
        switch dataType {
        case 0: return "未指定"
        case 1: return "公開証明書"
        case 2: return "共有資格情報"
        default: return "不明(\(dataType))"
        }
    }

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt64Field(value: &id)
            case 2: try decoder.decodeSingularInt32Field(value: &dataType)
            case 3: try decoder.decodeSingularBytesField(value: &data)
            case 5: try decoder.decodeSingularMessageField(value: &expirationTime)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if id != 0 { try visitor.visitSingularInt64Field(value: id, fieldNumber: 1) }
        if dataType != 0 {
            try visitor.visitSingularInt32Field(value: dataType, fieldNumber: 2)
        }
        if !data.isEmpty {
            try visitor.visitSingularBytesField(value: data, fieldNumber: 3)
        }
        if let expirationTime {
            try visitor.visitSingularMessageField(value: expirationTime, fieldNumber: 5)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbySharedCredential else { return false }
        return id == other.id && dataType == other.dataType
            && data == other.data && expirationTime == other.expirationTime
    }
}

// MARK: - PublicCertificate (RPC 版)

/// `SharedCredential.data` の中身。
///
/// ## Bada の `wire_format.proto` とは別物
///
/// 端末間でやりとりする `wire_format.proto` の `PublicCertificate` と
/// 名前は同じだが、**フィールド番号が違う**。実際のバイト列を
/// `ProtoInspector` にかけて確かめた結果がこれ。
///
/// ```
/// f1  bytes 32          secret_id
/// f2  bytes 32          secret_key          (Bada では authenticity_key)
/// f3  bytes 91          public_key          (P-256 の SubjectPublicKeyInfo)
/// f4  message           start_time          (google.protobuf.Timestamp)
/// f5  message           end_time            (同上)
/// f7  bytes 14          metadata_encryption_key
/// f8  bytes 162〜215    encrypted_metadata_bytes
/// f9  bytes 32          metadata_encryption_key_tag
/// f10 varint            for_self_share (bool)
/// f11 bytes 578〜587    (入れ子。証明書が長い個体だけに付く)
/// ```
///
/// Bada 側は 6 = `encrypted_metadata_bytes`、7 = `metadata_encryption_key_tag`
/// なので、**2 つずれている**。この食い違いのせいで、metadata を 0 件と
/// 誤認し、14 バイトの `metadata_encryption_key` を tag だと誤読していた。
///
/// 14 バイトという長さは Nearby Share の metadata 暗号鍵の仕様と一致する。
/// tag が 32 バイト (f9) なのも HMAC-SHA256 の出力として筋が通る。
struct NearbyPublicCertificate: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "nearby.sharing.proto.PublicCertificate"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    var secretId = Data()
    var secretKey = Data()
    var publicKey = Data()
    var startTime: SwiftProtobuf.Google_Protobuf_Timestamp?
    var endTime: SwiftProtobuf.Google_Protobuf_Timestamp?
    var metadataEncryptionKey = Data()
    var encryptedMetadataBytes = Data()
    var metadataEncryptionKeyTag = Data()
    /// `bool for_self_share = 10;`
    ///
    /// 上流の `rpc_resources.proto` で確認済み。実測で全件 1 だったのは、
    /// **降りてきたのが自分の端末向けの証明書だけ**だったということ。
    var forSelfShare = false
    /// f11。上流の proto では `reserved 11;` になっている枠。
    /// 実測では 578 バイトの入れ子が入っており、identity talisman の類と思われる。
    /// 用途が不明なので生のまま持っておく。
    var extraBlob = Data()

    /// `string binding_id = 12;`
    var bindingId = ""

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularBytesField(value: &secretId)
            case 2: try decoder.decodeSingularBytesField(value: &secretKey)
            case 3: try decoder.decodeSingularBytesField(value: &publicKey)
            case 4: try decoder.decodeSingularMessageField(value: &startTime)
            case 5: try decoder.decodeSingularMessageField(value: &endTime)
            case 7: try decoder.decodeSingularBytesField(value: &metadataEncryptionKey)
            case 8: try decoder.decodeSingularBytesField(value: &encryptedMetadataBytes)
            case 9: try decoder.decodeSingularBytesField(value: &metadataEncryptionKeyTag)
            case 10: try decoder.decodeSingularBoolField(value: &forSelfShare)
            case 11: try decoder.decodeSingularBytesField(value: &extraBlob)
            case 12: try decoder.decodeSingularStringField(value: &bindingId)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !secretId.isEmpty {
            try visitor.visitSingularBytesField(value: secretId, fieldNumber: 1)
        }
        if !secretKey.isEmpty {
            try visitor.visitSingularBytesField(value: secretKey, fieldNumber: 2)
        }
        if !publicKey.isEmpty {
            try visitor.visitSingularBytesField(value: publicKey, fieldNumber: 3)
        }
        if let startTime {
            try visitor.visitSingularMessageField(value: startTime, fieldNumber: 4)
        }
        if let endTime {
            try visitor.visitSingularMessageField(value: endTime, fieldNumber: 5)
        }
        if !metadataEncryptionKey.isEmpty {
            try visitor.visitSingularBytesField(value: metadataEncryptionKey, fieldNumber: 7)
        }
        if !encryptedMetadataBytes.isEmpty {
            try visitor.visitSingularBytesField(value: encryptedMetadataBytes, fieldNumber: 8)
        }
        if !metadataEncryptionKeyTag.isEmpty {
            try visitor.visitSingularBytesField(
                value: metadataEncryptionKeyTag, fieldNumber: 9
            )
        }
        if forSelfShare {
            try visitor.visitSingularBoolField(value: forSelfShare, fieldNumber: 10)
        }
        if !extraBlob.isEmpty {
            try visitor.visitSingularBytesField(value: extraBlob, fieldNumber: 11)
        }
        if !bindingId.isEmpty {
            try visitor.visitSingularStringField(value: bindingId, fieldNumber: 12)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyPublicCertificate else { return false }
        return secretId == other.secretId && secretKey == other.secretKey
    }
}

// MARK: - PublishDevice

/// `google.nearby.identity.v1.SharedCredential` (送信用)。
///
/// 受信用の `NearbySharedCredential` と同じ形だが、こちらは
/// `expiration_time` を載せる必要があるので別に定義する。
struct NearbyOutgoingSharedCredential: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "google.nearby.identity.v1.SharedCredential"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `int64 id = 1;`
    ///
    /// 上流は `util_hash::HighwayFingerprint64(secret_id)` を入れている。
    /// Google 内部のラッパーで鍵定数が読めないため、`secret_id` の先頭
    /// 8 バイトを入れて試す。サーバ側の索引にすぎなければ、これで通る。
    var id: Int64 = 0
    /// `DataType data_type = 2;` 1 = 公開証明書
    var dataType: Int32 = 0
    /// `bytes data = 3;` = `PublicCertificate` のシリアライズ
    var data = Data()
    /// `google.protobuf.Timestamp expiration_time = 5;`
    var expirationTime: SwiftProtobuf.Google_Protobuf_Timestamp?

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt64Field(value: &id)
            case 2: try decoder.decodeSingularInt32Field(value: &dataType)
            case 3: try decoder.decodeSingularBytesField(value: &data)
            case 5: try decoder.decodeSingularMessageField(value: &expirationTime)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if id != 0 { try visitor.visitSingularInt64Field(value: id, fieldNumber: 1) }
        if dataType != 0 {
            try visitor.visitSingularInt32Field(value: dataType, fieldNumber: 2)
        }
        if !data.isEmpty {
            try visitor.visitSingularBytesField(value: data, fieldNumber: 3)
        }
        if let expirationTime {
            try visitor.visitSingularMessageField(value: expirationTime, fieldNumber: 5)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyOutgoingSharedCredential else { return false }
        return id == other.id && data == other.data
    }
}

/// `google.nearby.identity.v1.PerVisibilitySharedCredentials`。
struct NearbyPerVisibilityCredentials: SwiftProtobuf.Message, Equatable {

    static let protoMessageName =
        "google.nearby.identity.v1.PerVisibilitySharedCredentials"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// 1 = 自分の他端末、2 = 連絡先。
    var visibility: Int32 = 0
    var sharedCredentials: [NearbyOutgoingSharedCredential] = []

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt32Field(value: &visibility)
            case 2: try decoder.decodeRepeatedMessageField(value: &sharedCredentials)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if visibility != 0 {
            try visitor.visitSingularInt32Field(value: visibility, fieldNumber: 1)
        }
        if !sharedCredentials.isEmpty {
            try visitor.visitRepeatedMessageField(
                value: sharedCredentials, fieldNumber: 2
            )
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyPerVisibilityCredentials else { return false }
        return visibility == other.visibility
            && sharedCredentials == other.sharedCredentials
    }
}

/// `google.nearby.identity.v1.Device`。
struct NearbyDevice: SwiftProtobuf.Message, Equatable {

    static let protoMessageName = "google.nearby.identity.v1.Device"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// `"devices/{device_id}"`。device_id は端末側で決める 10 文字。
    var name = ""
    var displayName = ""
    /// 0 未指定 / 1 自分 / 2 連絡先 / 3 連絡先(最新)
    var contact: Int32 = 0
    var perVisibilitySharedCredentials: [NearbyPerVisibilityCredentials] = []

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &name)
            case 2: try decoder.decodeSingularStringField(value: &displayName)
            case 3: try decoder.decodeSingularInt32Field(value: &contact)
            case 4: try decoder.decodeRepeatedMessageField(
                value: &perVisibilitySharedCredentials)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !name.isEmpty {
            try visitor.visitSingularStringField(value: name, fieldNumber: 1)
        }
        if !displayName.isEmpty {
            try visitor.visitSingularStringField(value: displayName, fieldNumber: 2)
        }
        if contact != 0 {
            try visitor.visitSingularInt32Field(value: contact, fieldNumber: 3)
        }
        if !perVisibilitySharedCredentials.isEmpty {
            try visitor.visitRepeatedMessageField(
                value: perVisibilitySharedCredentials, fieldNumber: 4
            )
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyDevice else { return false }
        return name == other.name && displayName == other.displayName
    }
}

/// `google.nearby.identity.v1.PublishDeviceRequest`。
struct NearbyPublishDeviceRequest: SwiftProtobuf.Message {

    static let protoMessageName = "google.nearby.identity.v1.PublishDeviceRequest"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    var device: NearbyDevice?

    init() {}

    init(device: NearbyDevice) { self.device = device }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularMessageField(value: &device)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if let device {
            try visitor.visitSingularMessageField(value: device, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? NearbyPublishDeviceRequest else { return false }
        return device == other.device
    }
}

/// `google.nearby.identity.v1.PublishDeviceResponse`。
///
/// `contact_updates` に `CONTACT_UPDATE_REMOVED` (2) が入っていたら、
/// 証明書を作り直してもう一度呼ぶ、というのが上流の作り。
struct NearbyPublishDeviceResponse: SwiftProtobuf.Message {

    static let protoMessageName = "google.nearby.identity.v1.PublishDeviceResponse"
    var unknownFields = SwiftProtobuf.UnknownStorage()

    /// 0 未指定 / 1 追加 / 2 削除
    var contactUpdates: [Int32] = []

    var contactRemoved: Bool { contactUpdates.contains(2) }

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeRepeatedInt32Field(value: &contactUpdates)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !contactUpdates.isEmpty {
            try visitor.visitPackedInt32Field(value: contactUpdates, fieldNumber: 1)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        message is NearbyPublishDeviceResponse
    }
}
