import AVFAudio
import Foundation

// The audio-session parts of ios/Sources/App/ConversationEngine.swift (configureAudioSession, startSilence,
// endConversation's deactivation, observeAudioSession), without the conversation logic: the controller decides
// when the mic is on and the engine reports interruptions and route changes as events. iOS only (AVAudioSession).

/// The app's audio session: voice chat while the mic is held, mixable silent playback otherwise, so iOS keeps
/// the app running in the background for the board (BLE keepalive, board audio) without touching other audio.
@MainActor
final class AudioSession: EngineAudioSession {
    typealias Change = AudioSessionChange

    private let silence = SilencePlayer()
    private var observers: [NSObjectProtocol] = []

    /// Called on the main thread
    var onChange: ((Change) -> Void)?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Diag.log("session: INTERRUPTION \(type == .began ? "began" : "ended") options \(options.rawValue)")
            MainActor.assumeIsolated {
                self?.onChange?(type == .began ? .interruptionBegan
                    : .interruptionEnded(shouldResume: options.contains(.shouldResume)))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            let route = AVAudioSession.sharedInstance().currentRoute
            Diag.log("session: route change \(raw) in=\(route.inputs.map(\.portName)) out=\(route.outputs.map(\.portName))")
            guard EngineMapping.reportsRouteChange(reason) else { return }
            let mapped = EngineMapping.route(inputs: route.inputs.map(\.portType))
            MainActor.assumeIsolated { self?.onChange?(.routeChanged(mapped)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Diag.log("session: MEDIA SERVICES RESET")
            MainActor.assumeIsolated { self?.onChange?(.mediaServicesReset) }
        })
    }

    /// Board mode (`InputRoute.board`): voiceChat, echo cancellation, routes through the AirPods mic; speech still
    /// plays in the earbuds. mixWithOthers + duckOthers: a video playing in another app gets quieter instead of
    /// stopping.
    /// Phone-only (ARCHITECTURE §5): the iPhone mic as the preferred input with the earbuds as A2DP output (or the
    /// loudspeaker without them); "Giữ để nói" asks for the headset mic over HFP.
    func configureForConversation(_ route: InputRoute) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers]
        options.insert(route.bluetooth == .hfp ? .allowBluetoothHFP : .allowBluetoothA2DP)
        if route.defaultToSpeaker { options.insert(.defaultToSpeaker) }
        try session.setCategory(.playAndRecord, mode: route.voiceChatMode ? .voiceChat : .default, options: options)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let inputs = session.availableInputs ?? []
        let preferred: AVAudioSessionPortDescription?
        switch route.preferredInput {
        case .automatic: preferred = nil
        case .builtInMic: preferred = inputs.first { $0.portType == .builtInMic }
        case .headset: preferred = inputs.first { EngineMapping.headsetInputs.contains($0.portType) }
        }
        // A missing port (no headset after all) leaves iOS's choice; never fatal
        do {
            try session.setPreferredInput(preferred)
        } catch {
            Diag.log("session: preferred input \(route.preferredInput.rawValue) failed: \(error.localizedDescription)")
        }
        let now = session.currentRoute
        Diag.log("session: route \(route.target.rawValue) in=\(now.inputs.map(\.portName)) out=\(now.outputs.map(\.portName))")
    }

    /// Earbuds or a headset as output or input (A2DP-only earbuds count: HFP is offered once asked for)
    var headsetConnected: Bool {
        let s = AVAudioSession.sharedInstance()
        let outputs: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return s.currentRoute.outputs.contains { outputs.contains($0.portType) }
            || (s.availableInputs ?? []).contains { EngineMapping.headsetInputs.contains($0.portType) }
    }

    /// The mic is taken: the silence is no longer needed to keep the app alive
    func stopSilence() {
        silence.stop()
    }

    /// Gives the session back: other apps return to full volume and the AirPods to A2DP
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Diag.log("session: deactivate failed: \(error.localizedDescription)")
        }
    }

    /// Mixable playback of silence (no mic, no ducking) so the app keeps running in the background
    func startSilence() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try silence.start()
        } catch {
            Diag.log("idle: silence start failed: \(error.localizedDescription)")
        }
    }

    /// Engine stopped: no silence, session released
    func release() {
        silence.stop()
        deactivate()
    }

    var currentRoute: AudioRoute {
        EngineMapping.route(inputs: AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType))
    }
}

/// Audio routes exist only on iOS (AVAudioSession)
extension EngineMapping {
    /// Headset when the mic is in earbuds or a headset, else the phone mic
    static func route(inputs: [AVAudioSession.Port]) -> AudioRoute {
        let headset: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .headsetMic, .usbAudio, .carAudio]
        return inputs.contains(where: headset.contains) ? .headset : .phoneMic
    }

    /// The inputs "Giữ để nói" asks for in phone-only
    static let headsetInputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .headsetMic, .usbAudio]

    /// A device came or went; category changes are the engine's own doing and not reported
    static func reportsRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep, .noSuitableRouteForCategory:
            true
        default:
            false
        }
    }
}
