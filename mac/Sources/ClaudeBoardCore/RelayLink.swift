import ClaudeRelay
import Foundation
import Network

/// Joins the relay server to the router (path .relay) and to the relay voice engine. Never decides anything:
/// board inputs go through the router to the same handlers as direct ones (RequestQueue checks id and shape).
public final class RelayLink: @unchecked Sendable {
    private let lock = NSLock()
    private var router: BoardRouter?
    private var voice: RelayVoiceEngine?
    private var sendFrame: (@Sendable (RelayFrame) -> Void)?
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) { self.log = log }

    public func connect(router: BoardRouter, voice: RelayVoiceEngine) {
        lock.withLock {
            self.router = router
            self.voice = voice
        }
    }

    /// Where frames for the iPhone go (the current RelayServer), nil while there is no listener
    public func attach(_ send: (@Sendable (RelayFrame) -> Void)?) { lock.withLock { sendFrame = send } }

    public func send(_ f: RelayFrame) { lock.withLock { sendFrame }?(f) }

    /// The router's relay path: one encoded board message, unchanged
    public func sendToBoard(_ m: BoardMessage) { send(.toBoard(m.encode())) }

    /// The server's authenticated relay came or went
    public func relayConnected(_ up: Bool) {
        guard !up else { return }   // the path is ready only once the iPhone also holds the board's relay role
        let (router, voice) = lock.withLock { (self.router, self.voice) }
        router?.pathReady(.relay, false)
        voice?.relayGone()
    }

    public func frame(_ f: RelayFrame) {
        let (router, voice) = lock.withLock { (self.router, self.voice) }
        switch f {
        case .boardLink(let up):
            log("relay: board link \(up ? "up" : "down") on the iPhone")
            router?.pathReady(.relay, up)
            if !up { voice?.relayGone() }
        case .fromBoard(let data):
            guard let input = BoardInput.decode(data) else {
                log("relay: unreadable board input dropped (\(data.count) bytes)")
                return
            }
            router?.input(input, from: .relay)
        case .voiceStatus(let why):
            voice?.setStatus(why)
            log("relay: iPhone voice \(why ?? "ready")")
        case .transcript, .voiceFailed:
            voice?.frame(f)
        default:
            break   // Mac-direction frames never get here (RelayFrame.decode checks the sender)
        }
    }
}

/// The relay server for the current Tailscale address: nothing without one, a new server when it changes.
/// The listener is bound to that one address; nothing else on the Mac (LAN, loopback, any) ever listens.
/// A listener failure (before or after it was listening) drops the server and reports `onListenerFailed`;
/// the daemon retries through the address watcher, so a retry also binds only the current Tailscale address.
public final class RelayHost: @unchecked Sendable {
    /// Set both before the first `addressChanged`. Called on the host's queue.
    public var onListenerFailed: (@Sendable () -> Void)? {
        get { lock.withLock { failedHandler } }
        set { lock.withLock { failedHandler = newValue } }
    }
    public var onListening: (@Sendable (UInt16) -> Void)? {
        get { lock.withLock { listeningHandler } }
        set { lock.withLock { listeningHandler = newValue } }
    }

    private let secret: RelaySecret
    private let link: RelayLink
    private let port: UInt16
    private let allowRemote: @Sendable (String) -> Bool
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var failedHandler: (@Sendable () -> Void)?      // lock
    private var listeningHandler: (@Sendable (UInt16) -> Void)?   // lock
    private let queue = DispatchQueue(label: "claude-board.relay-host")
    private var server: RelayServer?   // queue

    public init(secret: RelaySecret, link: RelayLink, port: UInt16,
                allowRemote: @escaping @Sendable (String) -> Bool = { TailscaleAddress.isTailscale($0) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secret = secret
        self.link = link
        self.port = port
        self.allowRemote = allowRemote
        self.log = log
    }

    public func addressChanged(_ newHost: String?) {
        queue.async { [self] in
            dropServer()
            guard let newHost else {
                log("iPhone relay off: no Tailscale address on this Mac")
                return
            }
            let s = RelayServer(secret: secret,
                                policy: .init(host: newHost, port: port, allowRemote: allowRemote), log: log)
            // Every callback is set before start, so no event is missed
            s.onRelay = { [link] up in link.relayConnected(up) }
            s.onFrame = { [link] f in link.frame(f) }
            s.onListenerFailed = { [weak self, weak s] in
                guard let self, let s else { return }
                self.queue.async { self.failed(s) }
            }
            server = s
            link.attach { [weak s] f in s?.send(f) }
            do {
                try s.start { [weak self, weak s] bound in
                    guard let self, let s else { return }
                    self.queue.async {
                        guard self.server === s else { return }   // superseded meanwhile
                        if let bound {
                            self.log("iPhone relay listening on \(newHost) port \(bound) (Tailscale only)")
                            self.onListening?(bound)
                        } else {
                            self.failed(s)
                        }
                    }
                }
            } catch {
                log("iPhone relay: listener not created: \(error)")
                failed(s)
            }
        }
    }

    /// On `queue`: the listener of `s` failed; ignored if `s` is no longer the current server
    private func failed(_ s: RelayServer) {
        guard server === s else { return }
        dropServer()
        onListenerFailed?()
    }

    /// On `queue`: stop the current server (its callbacks first, so a stale event never reaches the link)
    private func dropServer() {
        guard let old = server else { return }
        old.onRelay = nil
        old.onFrame = nil
        old.onListenerFailed = nil
        old.stop()
        server = nil
        link.attach(nil)
        link.relayConnected(false)
    }
}

/// Reports the Tailscale address to listen on whenever it changes, re-checking on every network path change
/// (NWPathMonitor: event-driven, no polling).
public final class RelayAddressWatcher: @unchecked Sendable {
    private let interfaces: @Sendable () -> [TailscaleAddress.Interface]
    private let onChange: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var reported = false
    private var last: String?
    private var monitor: NWPathMonitor?

    public init(interfaces: @escaping @Sendable () -> [TailscaleAddress.Interface] = { TailscaleAddress.interfaces() },
                onChange: @escaping @Sendable (String?) -> Void) {
        self.interfaces = interfaces
        self.onChange = onChange
    }

    public func refresh() {
        let now = TailscaleAddress.pick(interfaces())
        let changed = lock.withLock { () -> Bool in
            guard !reported || last != now else { return false }
            reported = true
            last = now
            return true
        }
        if changed { onChange(now) }
    }

    /// The next refresh reports even an unchanged address (after a listener failure: try binding again)
    public func forceNext() { lock.withLock { reported = false } }

    public func start(queue: DispatchQueue) {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        lock.withLock { monitor = m }
        m.start(queue: queue)
        queue.async { self.refresh() }
    }
}

/// How long to wait before re-creating a failed relay listener: 5 s, doubling up to 5 min, back to 5 s once a
/// listener comes up. `failures` tells a pending retry whether it is still the latest one.
public final class RelayBackoff: @unchecked Sendable {
    public static let first: TimeInterval = 5
    public static let limit: TimeInterval = 300
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var failures: Int { lock.withLock { count } }

    /// One more failure in a row: the delay before the next retry
    public func next() -> TimeInterval {
        lock.withLock {
            count += 1
            return min(Self.first * pow(2, Double(min(count - 1, 16))), Self.limit)
        }
    }

    public func reset() { lock.withLock { count = 0 } }
}
