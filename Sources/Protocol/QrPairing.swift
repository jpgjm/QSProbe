//
//  QrPairing.swift
//  QSProbe
//
//  送信側の QR ペアリング。Bada の `core-protocol/.../qr/` の Swift 移植から、
//  **送信に必要な部分だけ**を残したもの。
//
//  ## 役割の向き
//
//  **QR を出すのはファイルを送る側**、読み取るのは受け取る側です。
//
//  ```
//  QSProbe (送信)                        Android (受信)
//  --------------                        --------------
//  P-256 鍵ペアを生成
//  QR を表示 (公開鍵の X 座標 32 バイト)
//                                        カメラで読み取る
//                                        鍵を導出する
//                                        TLV type=1 を載せて mDNS 広告
//  広告を走査して TLV を照合
//  一致した相手に接続
//  qr_code_handshake_data で
//  鍵ペアの所有を証明
//  ```
//
//  BLE を使わないため、mDNS だけでは見つけてもらえない端末にも届きます。
//  実測では QR 経由だと Android 側の確認が出ず、約 90 ミリ秒で受理されます。
//
//  ## 導出
//
//  ```
//  keyData          = [00 00 versionByte] || X座標(32)        … 35 バイト
//  URL              = https://quickshare.google/qrcode#key=<urlsafe-base64(keyData)>
//  advertisingToken = HKDF-SHA256(ikm=keyData, salt="", info="advertisingContext", L=16)
//  nameEncryptionKey= HKDF-SHA256(ikm=keyData, salt="", info="encryptionKey",      L=16)
//  ```
//
//  salt は**常に空**です。RFC 5869 §2.2 で 32 バイトのゼロに置換されます。
//  選択の余地はなく、変えると全ての Quick Share ピアと相互運用できません。
//
//  ## 取り扱い注意
//
//  `QrKeyData` のバイト列と導出鍵は**ログに出さないこと**。nameEncryptionKey が
//  漏れると受動的な盗聴者にデバイス名を復元されます。
//

import Foundation
import CryptoKit

// MARK: - QR ペイロード

/// QR コード URL に埋まる 35 バイト。
///
/// ```
/// +----------------------+--------------------------+
/// |    bytes 0..2        |      bytes 3..34         |
/// | version prefix       | ECDSA P-256 の X 座標    |
/// | 00 00 02 / 00 00 03  |        (32 バイト)       |
/// +----------------------+--------------------------+
/// ```
struct QrKeyData: Equatable {

    static let versionPrefixLength = 3
    static let xCoordinateLength = 32
    static let totalLength = versionPrefixLength + xCoordinateLength
    static let defaultVersionByte: UInt8 = 0x02

    let versionByte: UInt8
    let xCoordinate: Data

    init?(versionByte: UInt8, xCoordinate: Data) {
        guard xCoordinate.count == Self.xCoordinateLength else { return nil }
        self.versionByte = versionByte
        self.xCoordinate = xCoordinate
    }

    func encode() -> Data {
        var out = Data([0x00, 0x00, versionByte])
        out.append(xCoordinate)
        return out
    }
}

/// 送信側が生成する鍵ペアと、それに対応する QR ペイロード。
struct QrKeyPair {
    let privateKey: P256.Signing.PrivateKey
    let keyData: QrKeyData

    static func generate(versionByte: UInt8 = QrKeyData.defaultVersionByte) -> QrKeyPair? {
        let privateKey = P256.Signing.PrivateKey()
        // x963 は 0x04 || X(32) || Y(32)
        let x963 = privateKey.publicKey.x963Representation
        guard x963.count == 65 else { return nil }
        let x = Data(x963[1..<33])
        guard let keyData = QrKeyData(versionByte: versionByte, xCoordinate: x) else { return nil }
        return QrKeyPair(privateKey: privateKey, keyData: keyData)
    }
}

// MARK: - URL

enum QrUrl {

    static let urlPrefix = "https://quickshare.google/qrcode"
    static let fragmentPrefix = "#key="

    static func build(_ keyData: QrKeyData) -> String {
        urlPrefix + fragmentPrefix + Base64Url.encode(keyData.encode())
    }
}

// MARK: - 鍵導出

struct DerivedQrKeys {
    /// 16 バイト。visible モードの TLV 値であり、hidden モードの AAD。
    let advertisingToken: Data
    /// 16 バイト。hidden モードでデバイス名を AES-128-GCM した鍵。
    let nameEncryptionKey: SymmetricKey
}

enum QrKeyDerivation {

    static let derivedKeyLength = 16

    static func deriveKeys(_ keyData: QrKeyData) -> DerivedQrKeys {
        let ikm = SymmetricKey(data: keyData.encode())
        let token = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data(),
            info: Data("advertisingContext".utf8),
            outputByteCount: derivedKeyLength
        )
        let nameKey = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data(),
            info: Data("encryptionKey".utf8),
            outputByteCount: derivedKeyLength
        )
        return DerivedQrKeys(
            advertisingToken: token.withUnsafeBytes { Data($0) },
            nameEncryptionKey: nameKey
        )
    }
}

// MARK: - hidden モードのデバイス名復号

enum QrHiddenNameCipher {

    static let ivLength = 12
    static let tagLength = 16
    /// IV(12) + 空の暗号文 + tag(16)。これ以下なら hidden 名 TLV ではない。
    static let minimumLength = ivLength + tagLength

    /// 復号できたらデバイス名を返す。できなければ nil (= この TLV は自分宛てではない)。
    static func open(_ value: Data, keys: DerivedQrKeys) -> String? {
        guard value.count > minimumLength else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: value)
            let plain = try AES.GCM.open(
                box,
                using: keys.nameEncryptionKey,
                authenticating: keys.advertisingToken
            )
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - TLV 照合

enum QrMatchResult: Equatable {
    case noMatch
    /// visible モードで advertisingToken が一致した。名前は EndpointInfo に平文で入っている。
    case visible
    /// hidden モードで復号できた。復号結果のデバイス名つき。
    case hidden(deviceName: String)
}

enum QrTlvMatcher {

    /// EndpointInfo の TLV に載る QR データの型番。
    static let tlvTypeQrCode = 1

    /// 発見した相手の EndpointInfo が、自分が出している QR に対応するものかを判定する。
    static func match(endpointInfo: EndpointInfo, keys: DerivedQrKeys) -> QrMatchResult {
        for record in endpointInfo.tlvRecords where record.type == tlvTypeQrCode {
            if record.value.count == keys.advertisingToken.count,
               constantTimeEquals(record.value, keys.advertisingToken) {
                return .visible
            }
            if let name = QrHiddenNameCipher.open(record.value, keys: keys) {
                return .hidden(deviceName: name)
            }
        }
        return .noMatch
    }

    /// 定数時間比較。`==` は最初に違うバイトで打ち切るため、
    /// advertisingToken の先頭何バイトを当てられたかが漏れる。
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<lhs.count {
            diff |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return diff == 0
    }
}

// MARK: - ハンドシェイク署名

enum QrHandshakeSigner {

    /// `qr_code_handshake_data` に載せる 64 バイトの署名を作る。
    ///
    /// QR に公開鍵を載せた側 (= 送信側) が、その鍵ペアを持っていることを証明する。
    /// 署名対象は **UKEY2 の authString**。PIN の元になっているのと同じ値なので、
    /// セッションごとに変わり、再生攻撃が効かない。
    ///
    /// 形式は **IEEE P1363**、つまり固定長の `R || S` (P-256 なら 64 バイト)。
    /// ASN.1 DER ではない。CryptoKit の `rawRepresentation` がまさに P1363 なので、
    /// Bada が Java でやっている DER → P1363 の変換は不要。
    static func sign(ukey2AuthKey: Data, privateKey: P256.Signing.PrivateKey) -> Data? {
        guard let signature = try? privateKey.signature(for: ukey2AuthKey) else { return nil }
        return signature.rawRepresentation
    }
}
