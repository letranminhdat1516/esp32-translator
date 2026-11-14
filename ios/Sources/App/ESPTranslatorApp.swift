import CoreBluetooth
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
    /// Track C: persisted switches, "Báo dịch sai", the history mirror
    private let data: DataCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let ui = UIState()
        // `-demo lockactivity`: the Live screen's demo data plus a real Live Activity (simulator screenshots)
        let lockActivityDemo = LiveActivityDemo.requested(CommandLine.arguments)
        let demo = DemoScreen.parse(CommandLine.arguments) ?? (lockActivityDemo ? .live : nil)
        let liveActivity: (any LiveActivityControlling)? =
            demo == nil || lockActivityDemo ? LiveActivitySetup.makeController() : nil
        // The board link; its central is created once Bluetooth was answered (the Permissions screen asks)
        let boardLink = ESPLink(startCentral: false)
        let pairing = LinkPairingModel(retryLink: { boardLink.retryPairing() }, onStart: { boardLink.activate() })
        // Demo mode shows the canvas' version label and keeps the canvas data in memory
        let services = demo == nil ? Self.liveServices(liveActivity: liveActivity, pairing: pairing)
            : AppServices(history: InMemoryHistoryStore(DemoData.history),
                          feedback: InMemoryFeedbackQueue(DemoData.feedback),
                          liveActivity: liveActivity, appVersion: "0.9")
        self.demo = demo
        let data = DataCoordinator(ui: ui, services: services, defaults: demo == nil ? .standard : nil)
        data.bind(observeHistory: demo == nil)
        self.data = data
        if let demo {
            // "Cho phép" grants at once in demo mode
            services.permissionActions = PermissionActions(request: { [weak services] kind in
                switch kind {
                case .microphone: services?.permissions.microphone = .granted
                case .bluetooth: services?.permissions.bluetooth = .granted
                case .speech: services?.permissions.speech = .granted
                }
            })
            let router = AppRouter(defaults: nil)
            let link = FakeBoardLink()
            controller = ConversationController(engine: FakeVoiceEngine(), board: link, packs: DemoData.packs,
                                                glossary: nil, defaults: UserDefaults(suiteName: "demo") ?? .standard,
                                                ui: ui, level: services.level, partials: services.partials)
            router.apply(demo)
            DemoData.seed(demo, ui: ui, services: services)
            _router = State(initialValue: router)
            Diag.log("demo \(demo.rawValue): fonts \(DSFamily.allCases.map { "\($0.rawValue)=\(DSFonts.isRegistered($0))" }), "
                     + "grotesk weights \([400.0, 500, 600, 700].map { DSFonts.resolvedWeight(.grotesk, $0) })")
        } else {
            let link = boardLink
            // Pairing steps to the Pair screen, in order on the main queue
            link.onPairingEvent = { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { pairing.handle(event) } }
            }
            if link.hasPinnedBoard { pairing.markPaired(name: PairingMachine.defaultName) }
            LivePermissions.wire(services) { link.activate() }
            link.onCentralUpdate = { [weak services] in
                DispatchQueue.main.async { MainActor.assumeIsolated { services?.permissionActions.refresh() } }
            }
            if CBManager.authorization != .notDetermined { link.activate() }
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
                                                glossary: glossary, boardText: BoardText(glyphs: glyphs), ui: ui,
                                                level: services.level, partials: services.partials)
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
        if demo == nil {
            // Track C: both clip rings (memory only; a clip is kept only for a line the user flags)
            let recorder = services.recorder
            MicPCMTap.connect(recorder, side: .mine)
            controller.onTheirPCM = { pcm, rate in recorder.append(pcm, sampleRate: rate, side: .theirs) }
            // Phone-only: the iPhone mic hears them, so its chunks go to their ring (back to mine after)
            controller.onMicSide = { side in MicPCMTap.connect(recorder, side: side) }
        }
    }

    /// Track C: the file-backed history and feedback queue (Application Support, excluded from backup) and the clip
    /// recorder; in-memory stand-ins when Application Support is unavailable.
    private static func liveServices(liveActivity: (any LiveActivityControlling)?,
                                     pairing: any PairingModeling) -> AppServices {
        var history: any HistoryStoring = InMemoryHistoryStore()
        var feedback: any FeedbackQueueing = InMemoryFeedbackQueue()
        do {
            history = FileHistoryStore(directory: try FileHistoryStore.defaultDirectory())
            feedback = FileFeedbackQueue(directory: try FileFeedbackQueue.defaultDirectory())
        } catch {
            Diag.log("data: no Application Support directory: \(error)")
        }
        return AppServices(history: history, feedback: feedback, recorder: RingAudioClipRecorder(),
                           liveActivity: liveActivity, pairing: pairing)
    }

    var body: some Scene {
        WindowGroup {
            RootView(ui: ui, router: router, services: services) {
                ui.forgetBoard()
                (services.pairing as? LinkPairingModel)?.reset()
                activityDriver.endNow()
                router.restartPairing()
            }
            // The conversation (and its mic prompt) waits until the permissions were asked: the language step or
            // a finished onboarding
            .task(id: router.onboardingDone || router.onboardingStep == .language) {
                if demo == nil, router.onboardingDone || router.onboardingStep == .language { await controller.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Track C: pending history is written when the app leaves the foreground
                if phase != .active { Task { await services.history.flush() } }
            }
        }
    }
}
