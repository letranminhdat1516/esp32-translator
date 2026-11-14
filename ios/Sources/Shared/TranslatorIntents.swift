import AppIntents
import Foundation

// The Live Activity buttons. `LiveActivityIntent`s run in the app process; the app sets the bridge's closures to
// its conversation controller at launch (track D wires them).

/// Routes the intents to the running app.
@MainActor
enum IntentBridge {
    static var stop: () -> Void = {}
    static var toggleBoardMic: () -> Void = {}
}

struct StopConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop conversation"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.stop()
        return .result()
    }
}

struct ToggleBoardMicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle board mic"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.toggleBoardMic()
        return .result()
    }
}
