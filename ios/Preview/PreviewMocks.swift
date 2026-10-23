// Stand-ins for the app types ContentView uses, so the real Sources/UI/ContentView.swift renders on the Mac
// with fake data (no Bluetooth, speech or translation). Same names and members as the real ones.
import Observation
import SwiftUI

enum ESPLink {
    enum State: Equatable { case off, scanning, connecting, ready }
}

@Observable
final class ConversationEngine {
    struct Line: Identifiable {
        let id = UUID()
        var source: String
        var target: String
        var unclear = false
        var turn = 0
        var at = Date()
    }

    enum Phase: Equatable {
        case idle
        case needsTranslationModels
        case preparing(String)
        case running
        case failed(String)
    }

    static let english = Locale.Language(identifier: "en")
    static let vietnamese = Locale.Language(identifier: "vi")

    var phase: Phase = .running
    var board: ESPLink.State = .ready
    var boardMicOn = true
    var theirLines: [Line] = []
    var theirPartial = ""
    var myLines: [Line] = []
    var myPartial = ""
    var listening = false

    func start() async { phase = .running }
    func translationModelsReady() { phase = .running }
    func toggleBoardMic() { boardMicOn.toggle() }
    func startConversation() { listening = true }

    func clearHistory() {
        theirLines.removeAll()
        myLines.removeAll()
        theirPartial = ""
        myPartial = ""
    }
}

@Observable
final class RelayModel {}

struct RelayView: View {
    let model: RelayModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Claude relay").font(.headline)
            Text("(not in the preview)").foregroundStyle(.secondary)
            Button("Close") { dismiss() }
        }
        .padding(40)
    }
}
