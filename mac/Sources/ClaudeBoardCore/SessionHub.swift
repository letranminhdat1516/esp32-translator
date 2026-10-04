import Foundation

public enum SessionSync {
    /// Messages that turn the board's rows `old` into `new`: removes first (the board never holds more than
    /// it shows), then the new or changed rows in board order.
    public static func diff(old: [UInt32: SessionRow], new: [SessionRow]) -> [BoardMessage] {
        let keep = Set(new.map(\.handle))
        var out: [BoardMessage] = old.keys.sorted().filter { !keep.contains($0) }.map { .sessionRemove(handle: $0) }
        for r in new where old[r.handle] != r { out.append(.session(r)) }
        return out
    }
}

/// Sessions as the board sees them. Rows flow only while the board shows Claude or the picker (battery):
/// a full sync (clear + rows) on activation or reconnect, then deltas. The focused session's "done" goes out
/// in any mode.
public actor SessionHub {
    private var tracker: SessionTracker
    private var mode: BoardMode = .other
    /// Rows the board holds; nil = it needs a full sync
    private var shown: [UInt32: SessionRow]?
    private let post: @Sendable (BoardMessage) async -> Void
    private let finished: @Sendable (String, String) async -> Void
    private let clock: @Sendable () -> Int64

    public init(sessionHooks: Bool,
                post: @escaping @Sendable (BoardMessage) async -> Void,
                finished: @escaping @Sendable (String, String) async -> Void,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.tracker = SessionTracker(sessionHooks: sessionHooks)
        self.post = post
        self.finished = finished
        self.clock = clock
    }

    public var focusedSessionId: String? { tracker.focusedId }

    public func tmuxPane(sessionId: String) -> String? { tracker.tmuxPane(sessionId: sessionId) }

    public func record(_ e: HookEvent) async {
        if case .focusedDone(let project, let line) = tracker.record(e, now: clock()) {
            await finished(project, line)
        }
        await push()
    }

    public func requestAnswered(sessionId: String) async {
        tracker.requestAnswered(sessionId, now: clock())
        await push()
    }

    public func boardInput(_ input: BoardInput) async {
        switch input {
        case .mode(let m):
            if mode == .picker && m != .picker { tracker.markAllSeen() }   // the user has looked at the rows
            if m == .other { shown = nil }
            mode = m
            await push()
        case .focus(let handle):
            if tracker.focus(handle: handle) { await push() }
        case .choice, .answers:
            break
        }
    }

    /// up: resync if the board is active (it reports its mode again right after subscribing);
    /// down: stop all session traffic until the board reports an active mode.
    public func boardConnected(_ up: Bool) async {
        shown = nil
        if up { await push() } else { mode = .other }
    }

    /// Every 60 s from the daemon: ended sessions leave, silent sessions end (no session hooks).
    public func tick() async {
        tracker.expire(now: clock())
        await push()
    }

    private func push() async {
        guard mode != .other else { return }
        let rows = tracker.rows()
        var messages: [BoardMessage] = shown == nil ? [.sessionsClear] : []
        messages += SessionSync.diff(old: shown ?? [:], new: rows)
        shown = Dictionary(uniqueKeysWithValues: rows.map { ($0.handle, $0) })   // before awaiting: reentrancy
        for m in messages { await post(m) }
    }
}
