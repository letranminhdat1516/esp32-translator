import AVFAudio

// One speech output for both users: AppleVoiceEngine speaks utterances by id (ttsStart/ttsEnd), the Swift app's
// ConversationEngine watches the queue (onBusyChange, quiet utterances).

/// Speaks the home-language translation into the AirPods with the best voice on the device.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Slightly faster than default to keep up with the conversation
    private let rate: Float = 0.54

    /// Utterances spoken with an id, held until they end: holding them keeps their identifiers from being reused
    /// by a later utterance at the same address
    private var ids: [ObjectIdentifier: (utterance: AVSpeechUtterance, id: Int)] = [:]

    /// Called with the utterance id when it starts, and when it finishes or is cancelled
    var onStart: ((Int) -> Void)?
    var onEnd: ((Int) -> Void)?

    /// Utterances queued or being spoken, the warm-up included
    private(set) var queued = 0 {
        didSet {
            if oldValue == 0 && queued > 0 { onBusyChange?(true) }
            if oldValue > 0 && queued <= 0 { onBusyChange?(false) }
        }
    }

    /// Called when the synthesizer starts speaking (true) and when its queue runs empty (false)
    var onBusyChange: ((Bool) -> Void)?

    /// `language` is a language code or locale identifier ("vi", "vi-VN")
    init(language: String) {
        synthesizer.usesApplicationAudioSession = true
        voice = EngineMapping.bestVoice(language) ?? AVSpeechSynthesisVoice(language: language)
        super.init()
        synthesizer.delegate = self
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Diag.log("tts: start \"\(u.speechString.prefix(40))\"")
        let key = ObjectIdentifier(u)
        Task { @MainActor in
            if let entry = self.ids[key] { self.onStart?(entry.id) }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Diag.log("tts: finish")
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.ended(key) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Diag.log("tts: cancel")
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.ended(key) }
    }

    private func ended(_ key: ObjectIdentifier) {
        queued -= 1
        if let entry = ids.removeValue(forKey: key) { onEnd?(entry.id) }
    }

    /// The engine's call: start and end are reported with `id`
    func speak(_ text: String, id: Int) {
        enqueue(text, id: id, quiet: false)
    }

    /// The Swift app's call: `quiet` halves the volume (while the user is speaking)
    func speak(_ text: String, quiet: Bool = false) {
        enqueue(text, id: nil, quiet: quiet)
    }

    private func enqueue(_ text: String, id: Int?, quiet: Bool) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        if quiet { utterance.volume = 0.5 }
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let id { ids[ObjectIdentifier(utterance)] = (utterance, id) }
        queued += 1
        Diag.log("tts: enqueue \(id.map(String.init) ?? "-") (queue \(queued)) \"\(text.prefix(40))\"")
        synthesizer.speak(utterance)
    }

    /// Cancels the current and all queued utterances; each reports its end
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Preloads the voice so the first phrase isn't delayed
    func warmUp() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.speak(utterance)
        queued += 1
    }

    var voiceName: String { voice?.name ?? "default" }
}
