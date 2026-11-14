import Foundation

// Compiled into the app and the widget extension (and the Mac test package). The Live Activity's buttons are
// `LiveActivityIntent`s: the system runs their `perform()` in the app process, launching the app if needed, so the
// app's `init` has set `IntentBridge.handler` by then. In the extension's own process the handler stays nil.

/// What a Live Activity button asks the app to do.
enum LiveActivityAction: String, Sendable, CaseIterable {
    /// "Dừng": stop the conversation and remove the activity.
    case stop
    /// "Tắt mic board" / "Bật mic board".
    case toggleBoardMic
}

/// Routes the intents to the running app.
@MainActor
enum IntentBridge {
    /// Set by the app at launch (`LiveActivityActions`).
    static var handler: ((LiveActivityAction) -> Void)?
    /// Actions that arrived before a handler was set, replayed when one is (an intent racing the app's launch).
    private(set) static var pending: [LiveActivityAction] = []

    static func perform(_ action: LiveActivityAction) {
        if let handler { handler(action) } else { pending.append(action) }
    }

    /// Installs `handler` and replays what arrived before it.
    static func install(_ handler: @escaping (LiveActivityAction) -> Void) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        for action in queued { handler(action) }
    }

    /// Tests: back to no handler, nothing queued.
    static func reset() {
        handler = nil
        pending.removeAll()
    }
}
