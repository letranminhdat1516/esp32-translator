import Foundation

/// Decides when the app holds the AirPods mic: only during a conversation.
///
/// While idle the app releases the mic and the audio session, so YouTube, TikTok and music play normally
/// (AirPods in high-quality A2DP). Speech on either side starts a conversation: the board streaming English,
/// the wearer's voice opening the gate, a translation to speak, or a tap (board mic or the app). After
/// `idleTimeout` with nobody speaking (no board audio, gate closed, nothing being spoken) it ends.
///
/// Pure value type, driven by `ConversationEngine`; time comes in with each event so it is unit-tested.
struct ConversationActivity {
    enum State: Equatable { case idle, active }

    enum Event: Equatable {
        /// An audio packet from the board mic (English speech)
        case boardAudio
        /// The wearer started / stopped speaking (VoiceGate)
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
    private(set) var state: State = .idle
    private(set) var lastSpeech = Date.distantPast
    private var gateIsOpen = false
    private var speaking = false

    init(idleTimeout: TimeInterval = 120) {
        self.idleTimeout = idleTimeout
    }

    var isActive: Bool { state == .active }

    /// Applies one event; returns a transition when the state changes
    mutating func handle(_ event: Event, at now: Date) -> Transition? {
        switch event {
        case .boardAudio, .userStart:
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

    private mutating func markSpeech(at now: Date) -> Transition? {
        lastSpeech = now
        guard state == .idle else { return nil }
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
