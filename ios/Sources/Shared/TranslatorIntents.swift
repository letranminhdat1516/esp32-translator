import AppIntents
import Foundation

// The Live Activity buttons. `LiveActivityIntent`s run in the app process (the type is compiled into both the app
// and the extension, which is what lets the system route it to the app); `IntentBridge` hands them to the app.

struct StopConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop conversation"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.perform(.stop)
        return .result()
    }
}

struct ToggleBoardMicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle board mic"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.perform(.toggleBoardMic)
        return .result()
    }
}
