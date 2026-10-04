import Foundation
import Network

/// The daemon's end of the iPhone relay: a WebSocket listener bound to exactly one address (the Mac's Tailscale
/// address; loopback in tests), mutual HMAC handshake, one authenticated relay at a time (the newest wins).
/// Everything runs on one serial queue.
public final class RelayServer: @unchecked Sendable {
    public struct Policy: Sendable {
        public var host: String
        public var port: UInt16
        /// Remote addresses allowed to connect at all (TailscaleAddress.isTailscale in the daemon)
        public var allowRemote: @Sendable (String) -> Bool
        public var handshakeTimeout: TimeInterval = 10
        public var maxFailures = 5
        public var failureWindow: TimeInterval = 60
        public var lockout: TimeInterval = 60

        public init(host: String, port: UInt16, allowRemote: @escaping @Sendable (String) -> Bool) {
            self.host = host
            self.port = port
            self.allowRemote = allowRemote
        }
    }

    /// Confined to `queue`, like the server's own state (the closures that capture it all run there)
    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let remote: String
        var handshake: ServerHandshake
        var authenticated = false
        var closed = false
        init(_ c: NWConnection, remote: String, handshake: ServerHandshake) {
            connection = c
            self.remote = remote
            self.handshake = handshake
        }
    }

    public var onRelay: (@Sendable (Bool) -> Void)?
    public var onFrame: (@Sendable (RelayFrame) -> Void)?

    private let secret: RelaySecret
    private let policy: Policy
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.relay")
    private var listener: NWListener?
    private var current: Session?
    private var failures: [Date] = []
    private var lockedUntil = Date.distantPast

    public init(secret: RelaySecret, policy: Policy, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secret = secret
        self.policy = policy
        self.log = log
    }

    /// `ready` gets the bound port once listening, or nil if the listener failed (address gone, port taken)
    public func start(ready: @escaping @Sendable (UInt16?) -> Void = { _ in }) throws {
        let params = WebSocketIO.parameters(serverKeepalive: true)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(policy.host),
                                                 port: NWEndpoint.Port(rawValue: policy.port) ?? .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready: ready(l?.port?.rawValue)
            case .failed(let e):
                self?.log("relay listener on \(self?.policy.host ?? "?") failed: \(e)")
                l?.cancel()
                ready(nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        queue.sync { listener = l }
        l.start(queue: queue)
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            if let s = current { close(s, "listener stopped", failed: false) }
        }
    }

    public func send(_ frame: RelayFrame) {
        queue.async { [self] in
            guard let s = current else { return }
            guard let data = frame.wire(from: .mac) else {   // the iPhone would close the connection over it
                log("relay: dropped a malformed or phone-direction frame")
                return
            }
            WebSocketIO.send(data, on: s.connection)
        }
    }

    private func accept(_ c: NWConnection) {
        guard Date() >= lockedUntil else {
            log("relay: connection refused (locked after failed handshakes)")
            c.cancel()
            return
        }
        guard let remote = WebSocketIO.host(of: c.endpoint), policy.allowRemote(remote) else {
            log("relay: connection from \(c.endpoint) refused (not a Tailscale address)")
            c.cancel()
            return
        }
        let s = Session(c, remote: remote, handshake: ServerHandshake(secret: secret))
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                WebSocketIO.send(s.handshake.challenge.encode(), on: c)
                self.receive(s)
            case .failed, .cancelled:
                self.close(s, nil, failed: !s.authenticated)
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + policy.handshakeTimeout) { [weak self] in
            guard let self, !s.authenticated, !s.closed else { return }
            self.close(s, "relay: handshake from \(remote) timed out", failed: true)
        }
        c.start(queue: queue)
    }

    private func receive(_ s: Session) {
        WebSocketIO.receive(on: s.connection) { [weak self] r in
            guard let self else { return }
            self.queue.async { self.handle(s, r) }   // receive callbacks already run on `queue`; this keeps it explicit
        }
    }

    private func handle(_ s: Session, _ r: WebSocketIO.Received) {
        guard !s.closed else { return }
        switch r {
        case .end:
            close(s, s.authenticated ? "relay: iPhone disconnected" : nil, failed: !s.authenticated)
        case .control:
            receive(s)
        case .binary(let data):
            guard let frame = RelayFrame.decode(data, from: .phone) else {
                close(s, "relay: malformed or wrong-direction frame from \(s.remote)", failed: !s.authenticated)
                return
            }
            if s.authenticated {
                onFrame?(frame)
                receive(s)
                return
            }
            switch s.handshake.receive(frame) {
            case .accepted(let welcome):
                s.authenticated = true
                WebSocketIO.send(welcome.encode(), on: s.connection)
                if let old = current {                    // the newest relay wins; the old one goes quietly
                    old.closed = true
                    old.connection.cancel()
                }
                current = s
                log("relay: iPhone authenticated (\(s.remote))")
                onRelay?(true)
                receive(s)
            case .rejected:
                close(s, "relay: handshake from \(s.remote) rejected", failed: true)
            }
        }
    }

    private func close(_ s: Session, _ why: String?, failed: Bool) {
        guard !s.closed else { return }
        s.closed = true
        s.connection.cancel()
        if let why { log(why) }
        if failed { recordFailure() }
        if s === current {
            current = nil
            onRelay?(false)
        }
    }

    private func recordFailure() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < policy.failureWindow } + [now]
        if failures.count >= policy.maxFailures {
            lockedUntil = now.addingTimeInterval(policy.lockout)
            failures = []
            log("relay: \(policy.maxFailures) failed handshakes: refusing connections for \(Int(policy.lockout)) s")
        }
    }
}
