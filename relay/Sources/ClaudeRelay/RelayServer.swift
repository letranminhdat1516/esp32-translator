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
        /// Definite handshake failures (rejected auth, a malformed frame, a timeout) from one remote address within
        /// `failureWindow` that lock that address out for `lockout`
        public var maxFailures = 5
        public var failureWindow: TimeInterval = 60
        public var lockout: TimeInterval = 60
        /// Unauthenticated connections held open at once, in total and per remote address
        public var maxPending = 4
        public var maxPendingPerRemote = 2

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
        /// Holds one of the gate's pending slots until it authenticates or closes
        var pending = true
        init(_ c: NWConnection, remote: String, handshake: ServerHandshake) {
            connection = c
            self.remote = remote
            self.handshake = handshake
        }
    }

    /// An authenticated relay is connected (true) or the current one is gone (false). Safe to set at any time;
    /// set it before `start` so no event is missed. Called on the server's queue.
    public var onRelay: (@Sendable (Bool) -> Void)? {
        get { callbacks.withLock { relayHandler } }
        set { callbacks.withLock { relayHandler = newValue } }
    }

    /// Phone-direction frames from the authenticated relay only. Same rules as `onRelay`.
    public var onFrame: (@Sendable (RelayFrame) -> Void)? {
        get { callbacks.withLock { frameHandler } }
        set { callbacks.withLock { frameHandler = newValue } }
    }

    /// The listener failed after `ready` had reported its port (before that, `ready(nil)` reports it): the server
    /// has closed everything and stopped. Same rules as `onRelay`.
    public var onListenerFailed: (@Sendable () -> Void)? {
        get { callbacks.withLock { listenerFailedHandler } }
        set { callbacks.withLock { listenerFailedHandler = newValue } }
    }

    /// How long the listener may sit in `.waiting` (address not there yet) before that counts as a failure
    static let listenerWaitLimit: TimeInterval = 10

    private let secret: RelaySecret
    private let policy: Policy
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.relay")
    private let callbacks = NSLock()
    private var relayHandler: (@Sendable (Bool) -> Void)?
    private var frameHandler: (@Sendable (RelayFrame) -> Void)?
    private var listenerFailedHandler: (@Sendable () -> Void)?
    // Everything below: only on `queue`
    private var listener: NWListener?
    private var stopped = false
    /// Every open connection (pending and the current relay), so stop() and deinit can cancel each one
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var current: Session?
    private var gate: HandshakeGate

    public init(secret: RelaySecret, policy: Policy, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secret = secret
        self.policy = policy
        self.log = log
        gate = HandshakeGate(maxFailures: policy.maxFailures, failureWindow: policy.failureWindow,
                             lockout: policy.lockout, maxPending: policy.maxPending,
                             maxPendingPerRemote: policy.maxPendingPerRemote)
    }

    deinit {
        // Nothing else holds the server now (every callback captures it weakly), so this cannot race the queue
        listener?.cancel()
        for s in sessions.values { s.connection.cancel() }
    }

    /// Listens on `policy.host` only. `ready` is called exactly once: with the bound port once listening, or nil if
    /// the listener failed first (address gone, port taken: no address reuse, so a second daemon fails here). It is
    /// not called at all if stop() or another start() supersedes this listener first. Calling start() again
    /// replaces the previous listener (open connections stay).
    public func start(ready: @escaping @Sendable (UInt16?) -> Void = { _ in }) throws {
        let params = WebSocketIO.parameters(serverKeepalive: true)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(policy.host),
                                                 port: NWEndpoint.Port(rawValue: policy.port) ?? .any)
        params.allowLocalEndpointReuse = false
        let l = try NWListener(using: params)
        let once = ReadyOnce(ready)
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            self.listenerState(l, state, once)
        }
        l.newConnectionHandler = { [weak self, weak l] c in
            guard let self, let l, self.listener === l else { c.cancel(); return }
            self.accept(c)
        }
        queue.sync {
            listener?.cancel()
            listener = l
            stopped = false
        }
        l.start(queue: queue)
    }

    /// Closes the listener and every connection; a handshake in flight can no longer authenticate
    public func stop() {
        queue.async { [self] in
            stopped = true
            listener?.cancel()
            listener = nil
            closeAll("relay: stopped")
        }
    }

    /// Sends to the current relay; dropped without one, or if the iPhone would refuse the frame
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

    private func listenerState(_ l: NWListener, _ state: NWListener.State, _ once: ReadyOnce) {
        guard listener === l else { return }                  // superseded or stopped
        switch state {
        case .ready:
            once.call(l.port?.rawValue)
        case .waiting(let e):
            log("relay listener on \(policy.host) waiting: \(e)")
            queue.asyncAfter(deadline: .now() + Self.listenerWaitLimit) { [weak self, weak l] in
                guard let self, let l, self.listener === l, case .waiting = l.state else { return }
                self.listenerFailed(l, "still waiting after \(Int(Self.listenerWaitLimit)) s: \(e)", once)
            }
        case .failed(let e):
            listenerFailed(l, "\(e)", once)
        default:
            break
        }
    }

    private func listenerFailed(_ l: NWListener, _ why: String, _ once: ReadyOnce) {
        log("relay listener on \(policy.host) failed: \(why)")
        l.cancel()
        listener = nil
        if once.call(nil) { return }                          // reported through ready(nil)
        stopped = true
        closeAll(nil)
        onListenerFailed?()
    }

    private func accept(_ c: NWConnection) {
        guard !stopped else { c.cancel(); return }
        guard let remote = WebSocketIO.host(of: c.endpoint), policy.allowRemote(remote) else {
            log("relay: connection from \(c.endpoint) refused (not a Tailscale address)")
            c.cancel()
            return
        }
        switch gate.admit(remote, now: Date()) {
        case .locked:
            log("relay: connection from \(remote) refused (locked after failed handshakes)")
            c.cancel()
            return
        case .busy:
            log("relay: connection from \(remote) refused (too many unauthenticated connections)")
            c.cancel()
            return
        case nil:
            break
        }
        let s = Session(c, remote: remote, handshake: ServerHandshake(secret: secret))
        sessions[ObjectIdentifier(s)] = s
        // Weak captures: the server's `sessions` owns each session, so stop() / deinit can always cancel it
        c.stateUpdateHandler = { [weak self, weak s] state in
            guard let self, let s, !s.closed else { return }
            switch state {
            case .ready:
                WebSocketIO.send(s.handshake.challenge.encode(), on: c)
                self.receive(s)
            case .failed, .cancelled:
                self.close(s, nil, failed: false)             // a network drop is not a handshake failure
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + policy.handshakeTimeout) { [weak self, weak s] in
            guard let self, let s, !s.authenticated, !s.closed else { return }
            self.close(s, "relay: handshake from \(remote) timed out", failed: true)
        }
        c.start(queue: queue)
    }

    private func receive(_ s: Session) {
        WebSocketIO.receive(on: s.connection) { [weak self, weak s] r in
            guard let self, let s else { return }
            self.queue.async { self.handle(s, r) }   // receive callbacks already run on `queue`; this keeps it explicit
        }
    }

    private func handle(_ s: Session, _ r: WebSocketIO.Received) {
        guard !s.closed else { return }
        guard !stopped else {
            close(s, nil, failed: false)
            return
        }
        switch r {
        case .end:
            close(s, s.authenticated ? "relay: iPhone disconnected" : nil, failed: false)
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
                releasePending(s)
                WebSocketIO.send(welcome.encode(), on: s.connection)
                let old = current
                current = s
                if let old { close(old, "relay: replaced by a newer iPhone connection", failed: false) }  // quietly
                log("relay: iPhone authenticated (\(s.remote))")
                onRelay?(true)
                receive(s)
            case .rejected:
                close(s, "relay: handshake from \(s.remote) rejected", failed: true)
            }
        }
    }

    private func closeAll(_ why: String?) {
        let open = Array(sessions.values)
        if let why, !open.isEmpty { log(why) }
        for s in open { close(s, nil, failed: false) }
    }

    /// `failed`: a definite handshake failure (counts toward the remote's lockout)
    private func close(_ s: Session, _ why: String?, failed: Bool) {
        guard !s.closed else { return }
        s.closed = true
        s.connection.cancel()
        sessions[ObjectIdentifier(s)] = nil
        releasePending(s)
        if let why { log(why) }
        if failed, gate.fail(s.remote, now: Date()) {
            log("relay: \(policy.maxFailures) failed handshakes from \(s.remote): refusing it for \(Int(policy.lockout)) s")
        }
        if s === current {
            current = nil
            onRelay?(false)
        }
    }

    private func releasePending(_ s: Session) {
        guard s.pending else { return }
        s.pending = false
        gate.release(s.remote)
    }
}

/// Who may start a handshake: a per-remote lockout after repeated definite failures, and caps on unauthenticated
/// connections (in total and per remote). Pure: time is passed in.
struct HandshakeGate {
    enum Refusal: Equatable { case locked, busy }

    let maxFailures: Int
    let failureWindow: TimeInterval
    let lockout: TimeInterval
    let maxPending: Int
    let maxPendingPerRemote: Int
    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var pending: [String: Int] = [:]

    init(maxFailures: Int, failureWindow: TimeInterval, lockout: TimeInterval, maxPending: Int,
         maxPendingPerRemote: Int) {
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.lockout = lockout
        self.maxPending = maxPending
        self.maxPendingPerRemote = maxPendingPerRemote
    }

    /// nil: admitted, holding one pending slot until release(remote)
    mutating func admit(_ remote: String, now: Date) -> Refusal? {
        prune(now)
        if lockedUntil[remote] != nil { return .locked }
        let total = pending.values.reduce(0, +)
        guard total < maxPending, pending[remote, default: 0] < maxPendingPerRemote else { return .busy }
        pending[remote, default: 0] += 1
        return nil
    }

    mutating func release(_ remote: String) {
        guard let n = pending[remote] else { return }
        pending[remote] = n > 1 ? n - 1 : nil
    }

    /// true when this failure locks `remote` out
    mutating func fail(_ remote: String, now: Date) -> Bool {
        prune(now)
        let recent = failures[remote, default: []] + [now]
        guard recent.count >= maxFailures else {
            failures[remote] = recent
            return false
        }
        failures[remote] = nil
        lockedUntil[remote] = now.addingTimeInterval(lockout)
        return true
    }

    var pendingCount: Int { pending.values.reduce(0, +) }

    private mutating func prune(_ now: Date) {
        lockedUntil = lockedUntil.filter { now < $0.value }
        failures = failures.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < failureWindow }
            return recent.isEmpty ? nil : recent
        }
    }
}

/// `start`'s ready callback, called at most once
private final class ReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UInt16?) -> Void)?
    init(_ handler: @escaping @Sendable (UInt16?) -> Void) { self.handler = handler }

    /// false if it was already called
    @discardableResult
    func call(_ port: UInt16?) -> Bool {
        guard let h = lock.withLock({ () -> (@Sendable (UInt16?) -> Void)? in
            defer { handler = nil }
            return handler
        }) else { return false }
        h(port)
        return true
    }
}
