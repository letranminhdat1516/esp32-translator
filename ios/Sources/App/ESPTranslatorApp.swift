import SwiftUI

@main
struct ESPTranslatorApp: App {
    @State private var engine = ConversationEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .task { await engine.start() }
        }
    }
}
