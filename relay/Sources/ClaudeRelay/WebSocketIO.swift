import Foundation
import Network

/// Binary WebSocket messages over Network.framework, shared by the server (Mac) and the client (iPhone).
enum WebSocketIO {
    /// WebSocket over plain TCP (Tailscale's WireGuard encrypts the path). The server adds TCP keepalive (idle 60 s,
    /// 15 s × 4 probes): the kernel notices a vanished iPhone without any app-level polling.
    static func parameters(serverKeepalive: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        if serverKeepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = RelayFrame.maxFrame
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    static func send(_ data: Data, on c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "relay", metadata: [meta])
        c.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    enum Received: Sendable { case binary(Data), control, end }

    /// One message: binary data, a ping / pong, or the end (close, error, a text message, nothing)
    static func receive(on c: NWConnection, _ handler: @escaping @Sendable (Received) -> Void) {
        c.receiveMessage { data, context, _, error in
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard error == nil, let meta else { handler(.end); return }
            switch meta.opcode {
            case .binary: handler(data.map(Received.binary) ?? .end)
            case .ping, .pong: handler(.control)
            default: handler(.end)
            }
        }
    }

    /// "100.101.102.103" / "fd7a:115c:a1e0::5" (zone dropped); nil for anything that is not an IP endpoint
    static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init)
        default: return nil
        }
    }
}
