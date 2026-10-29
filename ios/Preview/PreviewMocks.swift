// Stand-ins for the app types ContentView uses that need the phone (the Claude relay), so the real
// Sources/UI/ContentView.swift renders on the Mac with fake data. Same names as the real ones.
import Observation
import SwiftUI

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
