import SwiftUI

@main
struct ESPTranslatorApp: App {
    @State private var engine: ConversationEngine
    @State private var relay: RelayModel

    init() {
        let engine = ConversationEngine()
        _engine = State(initialValue: engine)
        _relay = State(initialValue: RelayModel(link: engine.link))   // starts relaying if a Mac is paired
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, relay: relay)
                .task { await engine.start() }
        }
    }
}
