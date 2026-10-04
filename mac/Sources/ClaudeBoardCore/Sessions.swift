import Foundation

/// Wire letters (firmware claude_proto.h): n needs you, w working, i idle, e ended
public enum SessionState: String, Sendable {
    case needsYou = "n", working = "w", idle = "i", ended = "e"
}

/// One picker row as the board receives it (message kind 4).
public struct SessionRow: Equatable, Sendable {
    public var handle: UInt32
    public var state: SessionState
    /// Unix seconds: when the current state began (elapsed time on the Claude screen)
    public var since: Int64
    /// Unix seconds: last hook event (picker order)
    public var updated: Int64
    public var focused: Bool
    /// A turn ended while another session was focused (badge)
    public var unseen: Bool
    public var project: String
    public var lastLine: String
    /// The session runs in a tmux pane its hooks reported (pane + socket + ancestry): voice commands can target it
    public var voice: Bool

    public init(handle: UInt32, state: SessionState, since: Int64, updated: Int64, focused: Bool, unseen: Bool,
                project: String, lastLine: String, voice: Bool = false) {
        self.handle = handle
        self.state = state
        self.since = since
        self.updated = updated
        self.focused = focused
        self.unseen = unseen
        self.project = project
        self.lastLine = lastLine
        self.voice = voice
    }

    /// Wire flags: bit0 focused, bit1 unseen, bit2 voice
    public var flags: Int { (focused ? 1 : 0) | (unseen ? 2 : 0) | (voice ? 4 : 0) }

    /// Picker order, identical on the board (sessions.c sessions_before): needs you first, then the most
    /// recently updated, then the higher handle.
    public static func boardOrder(_ a: SessionRow, _ b: SessionRow) -> Bool {
        let an = a.state == .needsYou, bn = b.state == .needsYou
        if an != bn { return an }
        if a.updated != b.updated { return a.updated > b.updated }
        return a.handle > b.handle
    }
}

/// What a voice command needs to know about a session (VoiceHub)
public struct VoiceTarget: Equatable, Sendable {
    public let sessionId: String
    public let project: String
    public let state: SessionState
    /// nil: the session never reported a tmux pane with its socket and ancestry ("Open with cb for voice")
    public let pane: PaneTarget?

    public init(sessionId: String, project: String, state: SessionState, pane: PaneTarget?) {
        self.sessionId = sessionId
        self.project = project
        self.state = state
        self.pane = pane
    }
}
