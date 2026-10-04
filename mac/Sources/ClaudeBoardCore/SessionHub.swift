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
    /// Board traffic in the order it was decided. `post` suspends (it hops to another actor), and other events
    /// run on the hub meanwhile: one drainer at a time keeps their messages in this order, so a newer row is
    /// never overtaken by an older one.
    private enum Out { case board(BoardMessage), finished(project: String, line: String) }
    private var outbox: [Out] = []
    private var draining = false

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
    public func voiceTarget(handle: UInt32) -> VoiceTarget? { tracker.voiceTarget(handle: handle) }

    public func record(_ e: HookEvent) async {
        if case .focusedDone(let project, let line) = tracker.record(e, now: clock()) {
            outbox.append(.finished(project: project, line: line))
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
        case .choice, .answers, .voiceStart, .voiceStop, .voiceCancel, .voiceSend:
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

    /// Queues what the board needs to match the tracker (nothing while it shows another mode), then delivers.
    private func push() async {
        guard mode != .other else { await deliver(); return }
        let rows = tracker.rows()
        var messages: [BoardMessage] = shown == nil ? [.sessionsClear] : []
        messages += SessionSync.diff(old: shown ?? [:], new: rows)
        shown = Dictionary(uniqueKeysWithValues: rows.map { ($0.handle, $0) })
        outbox += messages.map(Out.board)
        await deliver()
    }

    /// Hands the outbox over in order. A call that finds a drainer already running returns at once: that
    /// drainer delivers its messages too.
    private func deliver() async {
        guard !draining else { return }
        draining = true
        while !outbox.isEmpty {
            switch outbox.removeFirst() {
            case .board(let m): await post(m)
            case .finished(let project, let line): await finished(project, line)
            }
        }
        draining = false
    }
}

extension SessionHub {
    /// The rows as the tracker has them now (tests)
    var currentRows: [SessionRow] { tracker.rows() }
}
