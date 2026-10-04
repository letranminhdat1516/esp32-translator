import Darwin
import Foundation

/// Where the relay may listen and connect: Tailscale's addresses only (100.64.0.0/10 and fd7a:115c:a1e0::/48 on a
/// utun interface). 100.64/10 alone is not enough: carriers use it too (CGNAT), so the interface must be a tunnel.
public enum TailscaleAddress {
    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public static func isTailscale(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) & 0xFFC0_0000 == 0x6440_0000   // 100.64.0.0/10
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0.prefix(6)) }
            return b == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]                  // fd7a:115c:a1e0::/48
        }
        return false
    }

    /// The address to listen on: a Tailscale address on a utun interface, IPv4 preferred; nil = do not listen
    public static func pick(_ interfaces: [Interface]) -> String? {
        let ok = interfaces.filter { $0.name.hasPrefix("utun") && isTailscale($0.address) }
        return (ok.first { !$0.address.contains(":") } ?? ok.first)?.address
    }

    /// Every IPv4 / IPv6 address of every interface (getifaddrs; no subprocess, works under launchd)
    public static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Interface] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            out.append(Interface(name: String(cString: p.pointee.ifa_name), address: address))
        }
        return out
    }
}
