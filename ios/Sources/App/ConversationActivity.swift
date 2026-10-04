import Foundation

/// Decides when the app holds the AirPods mic: only during a conversation.
///
/// While idle the app releases the mic and the audio session, so YouTube, TikTok and music play normally
/// (AirPods in high-quality A2DP). A conversation starts with the board streaming English, a translation to
/// speak, or a tap (board mic or the app). The wearer's voice cannot start one: the AirPods mic is off while
/// idle, so the wearer taps before speaking. `gateOpen` only keeps a running conversation alive. After
/// `idleTimeout` (10 minutes, so pauses in a normal conversation don't drop the wearer's next sentence) with
/// nobody speaking (no board audio, gate closed, nothing being spoken) it ends.
///
/// If the engine cannot take the mic (`startFailed`), the conversation goes back to idle and automatic
/// events don't retry for `retryDelay`; a tap always retries.
///
/// Pure value type, driven by `ConversationEngine`; time comes in with each event so it is unit-tested.
struct ConversationActivity {
    enum State: Equatable { case idle, active }

    enum Event: Equatable {
        /// An audio packet from the board mic (English speech)
        case boardAudio
        /// The wearer started / stopped speaking (VoiceGate; only heard while a conversation holds the mic)
        case gateOpen, gateClosed
        /// The app started / finished speaking a translation into the AirPods
        case ttsStart, ttsEnd
        /// A tap: the board mic turned on, or the start control in the app
        case userStart
        /// The audio session was taken away for good (an interruption that should not resume)
        case stop
        /// Periodic check of the idle timeout
        case tick
    }

    /// What the engine must do with the mic and the audio session
    enum Transition: Equatable { case start, stop }

    let idleTimeout: TimeInterval
    let retryDelay: TimeInterval
    private(set) var state: State = .idle
    private(set) var lastSpeech = Date.distantPast
    private var gateIsOpen = false
    private var speaking = false
    /// After a failed start, automatic events don't start a conversation before this
    private var noAutoStartUntil = Date.distantPast

    init(idleTimeout: TimeInterval = 600, retryDelay: TimeInterval = 30) {
        self.idleTimeout = idleTimeout
        self.retryDelay = retryDelay
    }

    var isActive: Bool { state == .active }

    /// Applies one event; returns a transition when the state changes
    mutating func handle(_ event: Event, at now: Date) -> Transition? {
        switch event {
        case .userStart:
            noAutoStartUntil = .distantPast
            return markSpeech(at: now)
        case .boardAudio:
            return markSpeech(at: now)
        case .gateOpen:
            gateIsOpen = true
            return markSpeech(at: now)
        case .ttsStart:
            speaking = true
            return markSpeech(at: now)
        case .gateClosed:
            gateIsOpen = false
            if state == .active { lastSpeech = now }
            return nil
        case .ttsEnd:
            speaking = false
            if state == .active { lastSpeech = now }
            return nil
        case .stop:
            return goIdle()
        case .tick:
            guard state == .active, !gateIsOpen, !speaking,
                  now.timeIntervalSince(lastSpeech) >= idleTimeout else { return nil }
            return goIdle()
        }
    }

    /// The engine could not take the mic after `.start`: back to idle without a `.stop` transition (nothing
    /// to release), and no automatic restart for `retryDelay` so a failing mic isn't retried every second
    mutating func startFailed(at now: Date) {
        state = .idle
        gateIsOpen = false
        speaking = false
        noAutoStartUntil = now.addingTimeInterval(retryDelay)
    }

    private mutating func markSpeech(at now: Date) -> Transition? {
        lastSpeech = now
        guard state == .idle, now >= noAutoStartUntil else { return nil }
        state = .active
        return .start
    }

    private mutating func goIdle() -> Transition? {
        gateIsOpen = false
        speaking = false
        guard state == .active else { return nil }
        state = .idle
        return .stop
    }
}
