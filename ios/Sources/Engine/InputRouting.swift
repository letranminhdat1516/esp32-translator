import Foundation

// Where the iPhone's one audio input goes (ARCHITECTURE §5). Pure decisions, unit-tested on the Mac
// (InputRoutingTests); `AudioSession` applies a route to AVAudioSession and `AppleVoiceEngine` wires the mic.

/// Which recognizer the phone's mic feeds.
enum MicTarget: String, Hashable, Sendable {
    /// The home recognizer (your own words): normal board mode, and "Giữ để nói" in phone-only.
    case mine
    /// The other language's recognizer: phone-only while nobody holds "Giữ để nói" (the board is not there).
    case theirs
}

/// The input the session asks for (`AVAudioSession.setPreferredInput`).
enum PreferredInput: String, Hashable, Sendable {
    /// No preference (iOS picks: the AirPods mic when they are in).
    case automatic
    /// The iPhone's own mic.
    case builtInMic
    /// The headset's mic (AirPods over HFP, a wired headset).
    case headset
}

/// How Bluetooth earbuds are used.
enum BluetoothProfile: String, Hashable, Sendable {
    /// Hands-free profile: their mic is an input (voice-chat quality output).
    case hfp
    /// Output only (high quality): the input stays on the iPhone mic while the speech plays in the earbuds.
    case a2dp
}

/// One complete decision for the audio session and the mic.
struct InputRoute: Hashable, Sendable {
    var target: MicTarget
    var preferredInput: PreferredInput
    var bluetooth: BluetoothProfile
    /// Without earbuds, play speech on the loudspeaker rather than the earpiece (the phone lies between you).
    var defaultToSpeaker: Bool
    /// The own-voice gate (`VoiceGate`) filters the mic. Off for the other person on the iPhone mic (they are not
    /// the wearer) and while "Giữ để nói" is held (holding it says you are speaking).
    var gated: Bool

    /// The session mode: voice chat for the hands-free profile; the default mode for A2DP output, because voice
    /// chat pulls Bluetooth earbuds into HFP. The engine's input node does echo cancellation in both.
    var voiceChatMode: Bool { bluetooth == .hfp }

    /// Board mode: the board hears them, the phone's mic (AirPods when in) hears you through the gate. Exactly the
    /// session the app always used.
    static let board = InputRoute(target: .mine, preferredInput: .automatic, bluetooth: .hfp,
                                  defaultToSpeaker: false, gated: true)

    /// The route for `mode`. In phone-only: the iPhone mic feeds their recognizer with the earbuds (if any) kept as
    /// A2DP output; while `talkHeld`, the input switches to the headset mic (the iPhone mic without a headset) and
    /// feeds yours, ungated.
    static func plan(mode: InputMode, talkHeld: Bool, headsetConnected: Bool) -> InputRoute {
        switch mode {
        case .board:
            return .board
        case .phoneOnly where talkHeld && headsetConnected:
            return InputRoute(target: .mine, preferredInput: .headset, bluetooth: .hfp, defaultToSpeaker: false,
                              gated: false)
        case .phoneOnly where talkHeld:
            return InputRoute(target: .mine, preferredInput: .builtInMic, bluetooth: .a2dp, defaultToSpeaker: true,
                              gated: false)
        case .phoneOnly:
            return InputRoute(target: .theirs, preferredInput: .builtInMic, bluetooth: .a2dp, defaultToSpeaker: true,
                              gated: false)
        }
    }
}
