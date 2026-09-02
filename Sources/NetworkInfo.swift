//
//  NetworkInfo.swift
//  QSProbe
//
//  TXT レコード `IPv4=` 用に、Wi-Fi インターフェイス (en0) の
//  IPv4 アドレスを取得する。
//

import Foundation

enum NetworkInfo {

    /// en0 (Wi-Fi) のドット区切り IPv4 アドレス。取得できなければ nil。
    static func wifiIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: hostname)
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }
}
