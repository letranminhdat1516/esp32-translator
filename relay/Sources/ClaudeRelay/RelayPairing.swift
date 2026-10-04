import Foundation

/// What the iPhone needs to reach the daemon, as the QR code printed by `claude-board --pair` carries it:
/// claudeboard://relay?v=1&h=<tailscale address>&p=<port>&s=<base64url secret>
public struct RelayPairing: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let secret: RelaySecret

    public init(host: String, port: UInt16, secret: RelaySecret) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    public var url: String { "claudeboard://relay?v=1&h=\(host)&p=\(port)&s=\(secret.base64url)" }

    public var webSocketURL: URL {
        URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(port)/relay")!
    }

    /// nil unless it is exactly a version-1 pairing code for a Tailscale address
    public static func parse(_ text: String) -> RelayPairing? {
        guard let c = URLComponents(string: text), c.scheme == "claudeboard", c.host == "relay",
              let items = c.queryItems else { return nil }
        func one(_ name: String) -> String? {
            let v = items.filter { $0.name == name }
            return v.count == 1 ? v[0].value : nil
        }
        guard one("v") == "1", let host = one("h"), TailscaleAddress.isTailscale(host),
              let port = one("p").flatMap({ UInt16($0) }), port != 0,
              let secret = one("s").flatMap({ RelaySecret(base64url: $0) }) else { return nil }
        return RelayPairing(host: host, port: port, secret: secret)
    }
}
