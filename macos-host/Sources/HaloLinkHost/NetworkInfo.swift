//
//  NetworkInfo.swift
//  HaloLink macOS host
//
//  Enumerates local IPv4 addresses so the READY line can print a URL the tablet
//  can open.
//

import Foundation
import Darwin

enum NetworkInfo {
    struct Interface {
        let name: String
        let address: String
        let isLoopback: Bool
    }

    static func ipv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            let status = getnameinfo(address, length, &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let text = String(cString: host)
            result.append(Interface(name: name, address: text,
                                    isLoopback: name == "lo0" || text.hasPrefix("127.")))
        }
        return result
    }

    /// Best guess for the LAN address the tablet should use (Wi-Fi/Ethernet first).
    static func preferredLANAddress() -> String? {
        let interfaces = ipv4Interfaces().filter { !$0.isLoopback }
        let preferredPrefixes = ["en", "bridge", "utun"]
        for prefix in preferredPrefixes {
            if let match = interfaces.first(where: { $0.name.hasPrefix(prefix) }) {
                return match.address
            }
        }
        return interfaces.first?.address
    }

    static func activeLANAddresses() -> [String] {
        ipv4Interfaces().filter { !$0.isLoopback }.map { "\($0.name)=\($0.address)" }
    }
}
