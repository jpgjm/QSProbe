//
//  EndpointInfo.swift
//  QSProbe
//
//  Bada の `core-protocol/.../endpoint/EndpointInfo.kt` の Swift 移植。
//
//  バイト構成:
//  ```
//  +--------+-----------------+-------------+--------+----------------------+
//  | byte 0 |  bytes 1..16    |   byte 17   | byte18 |     trailing TLV     |
//  |--------|-----------------|-------------|--------|----------------------|
//  | packed | salt(2)+key(14) | name length | name   | type(1) length(1)    |
//  |  bits  |                 |   (1 byte)  | (UTF8) |    value(length)     |
//  +--------+-----------------+-------------+--------+----------------------+
//  ```
//
//  byte 0 のビット packing (MSB 先頭):
//  ```
//    bit:   7   6   5   4   3   2   1   0
//         \_______/   |   \_______/   |
//           version  vis  deviceType  reserved
//  ```
//

import Foundation

enum DeviceType: Int {
    case unknown = 0
    case phone = 1
    case tablet = 2
    case laptop = 3

    static func fromRaw(_ raw: Int) -> DeviceType {
        DeviceType(rawValue: raw) ?? .unknown
    }
}

struct TlvRecord: Equatable {
    let type: Int
    let value: Data
}

struct EndpointInfo: Equatable {

    static let headerLength = 1
    static let metadataLength = 16
    static let nameLengthBytes = 1
    static let tlvHeaderLength = 2

    /// stock Quick Share との相互運用のため、デバイス名は UTF-8 で 19 バイトに
    /// クランプする (Bada が実測で確認した上限)。
    static let maxInteropNameBytes = 19

    var version: Int = 1
    var hidden: Bool = false
    var deviceType: DeviceType = .tablet
    var reserved: Bool = false
    /// salt(2) + encrypted metadata key(14)。GMS を使わない実装ではランダムで良い。
    var metadata: Data
    var deviceName: String?
    var tlvRecords: [TlvRecord] = []

    // MARK: - Serialize

    func serialize() -> Data {
        let nameBytes: [UInt8] = hidden ? [] : Array((deviceName ?? "").utf8)

        var out = Data()
        out.append(Self.packHeader(
            version: version,
            hidden: hidden,
            deviceType: deviceType,
            reserved: reserved
        ))
        out.append(metadata)
        if !hidden {
            out.append(UInt8(nameBytes.count))
            out.append(contentsOf: nameBytes)
        }
        for record in tlvRecords {
            out.append(UInt8(record.type))
            out.append(UInt8(record.value.count))
            out.append(record.value)
        }
        return out
    }

    // MARK: - Parse

    /// 不正な入力では nil を返す。呼び出し側は「このピアを無視する」と解釈すること。
    static func parse(_ bytes: Data) -> EndpointInfo? {
        let b = [UInt8](bytes)
        guard b.count >= headerLength + metadataLength else { return nil }

        let header = Int(b[0])
        let version = (header >> 5) & 0b111
        let hidden = ((header >> 4) & 0b1) == 1
        let deviceTypeRaw = (header >> 1) & 0b111
        let reserved = (header & 0b1) == 1

        let metadata = Data(b[headerLength..<(headerLength + metadataLength)])
        var offset = headerLength + metadataLength

        var deviceName: String?
        if !hidden {
            guard offset + nameLengthBytes <= b.count else { return nil }
            let nameLen = Int(b[offset])
            offset += nameLengthBytes
            guard offset + nameLen <= b.count else { return nil }
            // 厳格な UTF-8 デコード。不正なら nil。
            guard let name = String(bytes: b[offset..<(offset + nameLen)], encoding: .utf8) else {
                return nil
            }
            deviceName = name
            offset += nameLen
        }

        var records: [TlvRecord] = []
        while offset < b.count {
            guard offset + tlvHeaderLength <= b.count else { return nil }
            let type = Int(b[offset])
            let length = Int(b[offset + 1])
            offset += tlvHeaderLength
            guard offset + length <= b.count else { return nil }
            records.append(TlvRecord(type: type, value: Data(b[offset..<(offset + length)])))
            offset += length
        }

        return EndpointInfo(
            version: version,
            hidden: hidden,
            deviceType: DeviceType.fromRaw(deviceTypeRaw),
            reserved: reserved,
            metadata: metadata,
            deviceName: deviceName,
            tlvRecords: records
        )
    }

    // MARK: - Helpers

    static func packHeader(
        version: Int,
        hidden: Bool,
        deviceType: DeviceType,
        reserved: Bool
    ) -> UInt8 {
        let visBit = hidden ? 1 : 0
        let resBit = reserved ? 1 : 0
        let packed = ((version & 0b111) << 5)
            | ((visBit & 0b1) << 4)
            | ((deviceType.rawValue & 0b111) << 1)
            | (resBit & 0b1)
        return UInt8(packed)
    }

    /// ランダムな 16 バイト metadata を作る。
    static func randomMetadata() -> Data {
        var bytes = [UInt8](repeating: 0, count: metadataLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// デバイス名を UTF-8 で `maxInteropNameBytes` に収まるよう切り詰める。
    /// マルチバイト文字の途中で切らないよう、文字単位で削っていく。
    static func clampName(_ name: String) -> String {
        var result = name
        while result.utf8.count > maxInteropNameBytes, !result.isEmpty {
            result.removeLast()
        }
        return result.isEmpty ? "iPad" : result
    }
}
