import Foundation
import Observation

/// The features behind the new screens, injected into the views (`.environment(services)`). Phase 0 holds stubs and
/// snapshots the views draw; the tracks replace the stubs and load the snapshots from the stores.
@Observable @MainActor
final class AppServices {
    @ObservationIgnored let history: any HistoryStoring
    @ObservationIgnored let feedback: any FeedbackQueueing
    @ObservationIgnored let recorder: any AudioClipRecording
    @ObservationIgnored let liveActivity: any LiveActivityControlling
    let pairing: any PairingModeling
    /// Hot values in their own leaf models (ARCHITECTURE §3).
    @ObservationIgnored let level: LevelModel
    @ObservationIgnored let partials: PartialModel

    var permissions = PermissionsSnapshot()
    /// The system prompts behind "Cho phép" (the app wires them; demo mode grants at once).
    @ObservationIgnored var permissionActions = PermissionActions()
    var historySessions: [HistorySession] = []
    var feedbackItems: [FeedbackItem] = []
    /// The Live Activity as it would show now (the in-app lock-screen preview).
    var activity: (info: TranslatorActivityStatic, state: TranslatorActivityState)?
    /// Text prefilled in the glossary's add field (demo mode).
    var glossaryDraft = ""
    /// The transcript line whose actions are open.
    var selectedLineID: String?
    /// Demo mode pins the clock so relative texts ("12 giây trước", "Hôm nay") match the canvas.
    @ObservationIgnored var now: () -> Date = { Date() }
    let appVersion: String

    init(history: any HistoryStoring = InMemoryHistoryStore(),
         feedback: any FeedbackQueueing = InMemoryFeedbackQueue(),
         recorder: any AudioClipRecording = NoopAudioClipRecorder(),
         liveActivity: (any LiveActivityControlling)? = nil,
         pairing: (any PairingModeling)? = nil,
         level: LevelModel? = nil,
         partials: PartialModel? = nil,
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") {
        self.history = history
        self.feedback = feedback
        self.recorder = recorder
        // Main-actor defaults are made here: default arguments are evaluated outside the actor
        self.liveActivity = liveActivity ?? NoopLiveActivityController()
        self.pairing = pairing ?? FakePairingModel()
        self.level = level ?? LevelModel()
        self.partials = partials ?? PartialModel()
        self.appVersion = appVersion
    }

    /// Reloads the snapshots from the stores.
    func refresh() async {
        historySessions = await history.sessions()
        feedbackItems = await feedback.items()
    }
}
