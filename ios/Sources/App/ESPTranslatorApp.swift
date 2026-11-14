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
    /// Live Activity (track D): screen model → activity, and the board-forgotten end.
    private let activityDriver: LiveActivityDriver
    private let activityObserver: LiveActivityObserver?

    init() {
        let ui = UIState()
        // `-demo lockactivity`: the Live screen's demo data plus a real Live Activity (simulator screenshots)
        let lockActivityDemo = LiveActivityDemo.requested(CommandLine.arguments)
        let demo = DemoScreen.parse(CommandLine.arguments) ?? (lockActivityDemo ? .live : nil)
        let liveActivity: (any LiveActivityControlling)? =
            demo == nil || lockActivityDemo ? LiveActivitySetup.makeController() : nil
        // Demo mode shows the canvas' version label
        let services = demo == nil ? AppServices(liveActivity: liveActivity)
                                   : AppServices(liveActivity: liveActivity, appVersion: "0.9")
        self.demo = demo
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
        // The Live Activity: follows the conversation (listening, latest phrase pair, board mic, battery); its
        // buttons run in this process through the bridge
        let driver = LiveActivityDriver(controller: services.liveActivity)
        activityDriver = driver
        IntentBridge.install { LiveActivityActions.handle($0, ui: ui, driver: driver) }
        if demo == nil || lockActivityDemo {
            // An activity left by a crash or a kill of an earlier run goes away at launch
            services.liveActivity.end()
            activityObserver = LiveActivityObserver(ui: ui, driver: driver)
            LiveActivitySetup.installTerminationHook()
        } else {
            activityObserver = nil
        }
        _ui = State(initialValue: ui)
        _services = State(initialValue: services)
    }

    var body: some Scene {
        WindowGroup {
            RootView(ui: ui, router: router, services: services) {
                ui.forgetBoard()
                activityDriver.endNow()
                router.restartPairing()
            }
            .task { if demo == nil { await controller.start() } }
        }
    }
}
