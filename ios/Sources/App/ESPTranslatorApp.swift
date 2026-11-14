import SwiftUI
import UIKit

/// The composition root: the real engine, board link, glossary file and bundled language data, wired by the
/// conversation controller into one `UIState` for the views. With `-demo <screen>` (ios/Tools/snap.sh) the fakes
/// stand in for the engine and the board, the canvas sample data is seeded and that screen opens directly.
@main
struct ESPTranslatorApp: App {
    @State private var ui: UIState
    @State private var router: AppRouter
    @State private var services: AppServices
    private let controller: ConversationController
    private let demo: DemoScreen?
    /// Track C: persisted switches, "Báo dịch sai", the history mirror
    private let data: DataCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let ui = UIState()
        let demo = DemoScreen.parse(CommandLine.arguments)
        // Demo mode shows the canvas' version label and keeps the canvas data in memory
        let services = demo == nil ? Self.liveServices()
            : AppServices(history: InMemoryHistoryStore(DemoData.history),
                          feedback: InMemoryFeedbackQueue(DemoData.feedback), appVersion: "0.9")
        self.demo = demo
        let data = DataCoordinator(ui: ui, services: services, defaults: demo == nil ? .standard : nil)
        data.bind(observeHistory: demo == nil)
        self.data = data
        if let demo {
            let router = AppRouter(defaults: nil)
            let link = FakeBoardLink()
            controller = ConversationController(engine: FakeVoiceEngine(), board: link, packs: DemoData.packs,
                                                glossary: nil, defaults: UserDefaults(suiteName: "demo") ?? .standard,
                                                ui: ui)
            router.apply(demo)
            DemoData.seed(demo, ui: ui, services: services)
            _router = State(initialValue: router)
            Diag.log("demo \(demo.rawValue): fonts \(DSFamily.allCases.map { "\($0.rawValue)=\(DSFonts.isRegistered($0))" }), "
                     + "grotesk weights \([400.0, 500, 600, 700].map { DSFonts.resolvedWeight(.grotesk, $0) })")
        } else {
            let link = ESPLink()
            let glossary: GlossaryStore?
            do {
                glossary = GlossaryStore(directory: try GlossaryStore.defaultDirectory())
            } catch {
                Diag.log("glossary: no Application Support directory: \(error)")
                glossary = nil
            }
            // The board's CJK/Hangul/Thai glyph lists, loaded before any subtitle is encoded
            let glyphs = BoardGlyphSets.shared
            let packs = BundledPacks.load()
            controller = ConversationController(engine: AppleVoiceEngine.live(packs: packs), board: link, packs: packs,
                                                glossary: glossary, boardText: BoardText(glyphs: glyphs), ui: ui)
            ui.forgetBoard = { link.forgetBoard() }   // P9: the link pins the first board; this lets a new one in
            _router = State(initialValue: AppRouter())
            // Midnight, a time zone or daylight-saving change, or a clock set: keep the board's lock-face clock right
            NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                                   object: nil, queue: .main) { _ in
                NSTimeZone.resetSystemTimeZone()
                link.sendTime()
            }
        }
        // The Live Activity buttons run in this process (track D completes the wiring)
        IntentBridge.stop = { if ui.listening { ui.startStop() } }
        IntentBridge.toggleBoardMic = { ui.toggleBoardMic() }
        _ui = State(initialValue: ui)
        _services = State(initialValue: services)
        if demo == nil {
            // Track C: both clip rings (memory only; a clip is kept only for a line the user flags)
            let recorder = services.recorder
            MicPCMTap.connect(recorder, side: .mine)
            controller.onTheirPCM = { pcm, rate in recorder.append(pcm, sampleRate: rate, side: .theirs) }
        }
    }

    /// Track C: the file-backed history and feedback queue (Application Support, excluded from backup) and the clip
    /// recorder; in-memory stand-ins when Application Support is unavailable.
    private static func liveServices() -> AppServices {
        var history: any HistoryStoring = InMemoryHistoryStore()
        var feedback: any FeedbackQueueing = InMemoryFeedbackQueue()
        do {
            history = FileHistoryStore(directory: try FileHistoryStore.defaultDirectory())
            feedback = FileFeedbackQueue(directory: try FileFeedbackQueue.defaultDirectory())
        } catch {
            Diag.log("data: no Application Support directory: \(error)")
        }
        return AppServices(history: history, feedback: feedback, recorder: RingAudioClipRecorder())
    }

    var body: some Scene {
        WindowGroup {
            RootView(ui: ui, router: router, services: services) {
                ui.forgetBoard()
                router.restartPairing()
            }
            .task { if demo == nil { await controller.start() } }
            .onChange(of: scenePhase) { _, phase in
                // Track C: pending history is written when the app leaves the foreground
                if phase != .active { Task { await services.history.flush() } }
            }
        }
    }
}
