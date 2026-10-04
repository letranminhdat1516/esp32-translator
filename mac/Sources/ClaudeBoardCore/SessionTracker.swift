import Foundation

public enum TrackerEffect: Equatable, Sendable {
    case none
    /// The focused session finished a turn: chime + last line on the board, in any board mode
    case focusedDone(project: String, line: String)
}

/// Claude Code sessions as seen through hooks. Pure: the caller passes the time (Unix seconds).
public struct SessionTracker: Sendable {
    public static let visibleMax = 6
    public static let endedKeepSeconds: Int64 = 10 * 60
    public static let idleEndSeconds: Int64 = 2 * 60 * 60

    struct Session: Equatable, Sendable {
        let handle: UInt32
        var project: String
        var state: SessionState
        var since: Int64
        var updated: Int64
        var lastLine: String
        var tmuxPane: String?
        var unseen: Bool
    }

    /// SessionStart / SessionEnd hooks are installed (hook spike). Without them a session ends after 2 h
    /// without events.
    public let sessionHooks: Bool
    private(set) var sessions: [String: Session] = [:]
    public private(set) var focusedId: String?
    var nextHandle: UInt32 = 1

    public init(sessionHooks: Bool) { self.sessionHooks = sessionHooks }

    @discardableResult
    public mutating func record(_ e: HookEvent, now: Int64) -> TrackerEffect {
        guard !e.sessionId.isEmpty else { return .none }
        var s = sessions[e.sessionId] ?? newSession(now: now)
        if !e.cwd.isEmpty { s.project = Summary.project(cwd: e.cwd) }
        if let pane = e.tmuxPane, !pane.isEmpty { s.tmuxPane = pane }
        s.updated = now
        if focusedId.map({ sessions[$0] == nil }) ?? true { focusedId = e.sessionId }
        var effect = TrackerEffect.none
        switch e.name {
        case "SessionStart":
            Self.set(&s, .idle, now)
        case "UserPromptSubmit":
            Self.set(&s, .working, now)
        case "PermissionRequest":
            Self.set(&s, .needsYou, now)
        case "Notification":
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog": Self.set(&s, .needsYou, now)
            case "idle_prompt": Self.set(&s, .idle, now)
            default: break
            }
        case "Stop":
            Self.set(&s, .idle, now)
            s.lastLine = Summary.lastLine(e)
            if focusedId == e.sessionId {
                effect = .focusedDone(project: s.project, line: s.lastLine)
            } else {
                s.unseen = true
            }
        case "SessionEnd":
            Self.set(&s, .ended, now)
        default:
            break
        }
        sessions[e.sessionId] = s
        return effect
    }

    /// The board answered this session's request: Claude continues.
    public mutating func requestAnswered(_ sessionId: String, now: Int64) {
        guard var s = sessions[sessionId], s.state == .needsYou else { return }
        Self.set(&s, .working, now)
        s.updated = now
        sessions[sessionId] = s
    }

    @discardableResult
    public mutating func focus(handle: UInt32) -> Bool {
        guard let id = sessions.first(where: { $0.value.handle == handle })?.key else { return false }
        focusedId = id
        sessions[id]?.unseen = false
        return true
    }

    public mutating func markAllSeen() {
        for id in sessions.keys { sessions[id]?.unseen = false }
    }

    public mutating func expire(now: Int64) {
        for (id, s) in sessions {
            if s.state == .ended {
                if now - s.since >= Self.endedKeepSeconds { sessions[id] = nil }
            } else if !sessionHooks && now - s.updated >= Self.idleEndSeconds {
                var ended = s
                Self.set(&ended, .ended, now)
                sessions[id] = ended
            }
        }
        if let f = focusedId, sessions[f] == nil { focusedId = nil }
    }

    /// At most `visibleMax` rows in board order; the focused session is always one of them.
    public func rows() -> [SessionRow] {
        let all = sessions.map { id, s in
            SessionRow(handle: s.handle, state: s.state, since: s.since, updated: s.updated,
                       focused: id == focusedId, unseen: s.unseen && id != focusedId,
                       project: s.project, lastLine: s.lastLine)
        }.sorted(by: SessionRow.boardOrder)
        var top = Array(all.prefix(Self.visibleMax))
        if let f = all.first(where: \.focused), !top.contains(f), !top.isEmpty {
            top[top.count - 1] = f
            top.sort(by: SessionRow.boardOrder)
        }
        return top
    }

    public func tmuxPane(sessionId: String) -> String? { sessions[sessionId]?.tmuxPane }

    private mutating func newSession(now: Int64) -> Session {
        let handle = nextHandle
        nextHandle = nextHandle == .max ? 1 : nextHandle + 1   // handles are never 0
        return Session(handle: handle, project: "Claude", state: .idle, since: now, updated: now,
                       lastLine: "", tmuxPane: nil, unseen: false)
    }

    private static func set(_ s: inout Session, _ state: SessionState, _ now: Int64) {
        if s.state != state {
            s.state = state
            s.since = now
        }
    }
}
