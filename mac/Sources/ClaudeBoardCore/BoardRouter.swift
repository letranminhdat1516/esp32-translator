import Foundation

/// How the board is reached: direct BLE, or the iPhone relay over Tailscale.
public enum BoardPath: String, Sendable { case direct, relay }

/// The board as the daemon sees it, over whichever path is active (spec: "the daemon prefers direct BLE,
/// otherwise the relay"). Direct wins whenever it is ready, except when the board reports its mode over the relay
/// while direct still looks ready: the board has lost the Mac link first (it prefers direct too), so the relay
/// stays active until direct reconnects or sends an input. Any other input over the inactive relay is dropped.
/// Every change of active path reaches the daemon as a disconnect then a connect: requests fall through, voice
/// cancels, sessions resync, the clock is resent; an input that answers or types and arrives with the change is
/// dropped, since nothing shown before belongs to the new path.
/// Path events are handled in order on one queue; `send` goes straight to the active path.
public final class BoardRouter: BoardLinking, @unchecked Sendable {
    public var onInput: (@Sendable (BoardInput) -> Void)?
    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    public var onVoiceAudio: (@Sendable (Data) -> Void)?

    private let sendOn: @Sendable (BoardPath, BoardMessage) -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.router")
    private let lock = NSLock()
    private var ready: Set<BoardPath> = []   // lock
    private var active: BoardPath?           // lock
    private var directStale = false          // queue

    public init(send: @escaping @Sendable (BoardPath, BoardMessage) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sendOn = send
        self.log = log
    }

    public var activePath: BoardPath? { lock.withLock { active } }
    public var isReady: Bool { activePath != nil }

    public func send(_ message: BoardMessage) {
        guard let path = activePath else { return }
        sendOn(path, message)
    }

    public func pathReady(_ path: BoardPath, _ up: Bool) { queue.async { self.setReady(path, up) } }
    public func input(_ input: BoardInput, from path: BoardPath) { queue.async { self.route(input, path) } }
    public func voiceAudio(_ packet: Data, from path: BoardPath) {
        queue.async { if self.activePath == path { self.onVoiceAudio?(packet) } }
    }

    /// Waits until every event queued so far has been handled (tests)
    func flush() { queue.sync {} }

    private func setReady(_ path: BoardPath, _ up: Bool) {
        let changed = lock.withLock { () -> Bool in
            let was = ready.contains(path)
            if up { ready.insert(path) } else { ready.remove(path) }
            return was != up
        }
        guard changed else { return }
        if path == .direct && up { directStale = false }   // a fresh direct link: the board prefers it again
        log("\(path.rawValue) path \(up ? "ready" : "down")")
        reselect()
    }

    private func route(_ input: BoardInput, _ path: BoardPath) {
        guard lock.withLock({ ready.contains(path) }) else {
            log("board input over the \(path.rawValue) path dropped: that path is not ready")
            return
        }
        if path == .relay && activePath == .direct {
            // Only the board's mode report (sent on every (re)connect) means it moved to the relay
            guard case .mode = input else {
                log("board input over the relay dropped: the direct path is active")
                return
            }
            directStale = true
            log("the board reports its mode over the relay: it lost the direct link")
        }
        if path == .direct { directStale = false }
        guard reselect() else { onInput?(input); return }
        // The daemon just saw a disconnect then a connect: nothing shown before belongs to the new path,
        // so an input that answers or types is never delivered (the request falls through to the terminal)
        if Self.answers(input) {
            log("board input dropped: it arrived as the board path changed and cannot answer anything shown now")
            return
        }
        onInput?(input)
    }

    /// Inputs that answer a request or start / finish voice that types
    static func answers(_ input: BoardInput) -> Bool {
        switch input {
        case .choice, .answers, .voiceStart, .voiceStop, .voiceSend: true
        case .mode, .focus, .voiceCancel: false
        }
    }

    /// true when the active path changed
    @discardableResult
    private func reselect() -> Bool {
        let (old, new) = lock.withLock { () -> (BoardPath?, BoardPath?) in
            let pick: BoardPath? =
                ready.contains(.direct) && !directStale ? .direct
                : ready.contains(.relay) ? .relay
                : ready.contains(.direct) ? .direct
                : nil
            defer { active = pick }
            return (active, pick)
        }
        guard old != new else { return false }
        log("BOARD PATH SWITCHED: \(old?.rawValue ?? "none") -> \(new?.rawValue ?? "none")")
        if old != nil { onConnectionChange?(false) }
        if new != nil { onConnectionChange?(true) }
        return true
    }
}
