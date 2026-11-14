import SwiftUI
import UIKit

/// The composition root: the real engine, board link, glossary file and bundled language data, wired by the
/// conversation controller into one `UIState` for the views. The Claude relay shares the board link (P9).
@main
struct ESPTranslatorApp: App {
    @State private var ui: UIState
    @State private var relay: RelayModel
    private let controller: ConversationController

    init() {
        let link = ESPLink()
        let ui = UIState()
        let glossary: GlossaryStore?
        do {
            glossary = GlossaryStore(directory: try GlossaryStore.defaultDirectory())
        } catch {
            Diag.log("glossary: no Application Support directory: \(error)")
            glossary = nil
        }
        // The board's CJK/Hangul/Thai glyph lists, loaded before any subtitle is encoded
        let glyphs = BoardGlyphSets.shared
        controller = ConversationController(engine: AppleVoiceEngine.live(), board: link, packs: BundledPacks.load(),
                                            glossary: glossary, boardText: BoardText(glyphs: glyphs), ui: ui)
        ui.forgetBoard = { link.forgetBoard() }   // P9: the link pins the first board; this lets a new one in
        _ui = State(initialValue: ui)
        _relay = State(initialValue: RelayModel(link: link))   // starts relaying if a Mac is paired
        // Midnight, a time zone or daylight-saving change, or a clock set: keep the board's lock-face clock right
        NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                               object: nil, queue: .main) { _ in
            NSTimeZone.resetSystemTimeZone()
            link.sendTime()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ui: ui, relay: relay)
                .task { await controller.start() }
        }
    }
}
