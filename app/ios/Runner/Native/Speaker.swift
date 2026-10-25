import AVFAudio

// Copied from ios/Sources/Speech/Speaker.swift (the Swift app keeps its own copy until P8).
// Changes: the language comes from the pair (no locale literal), each utterance carries the id Dart gave it
// and reports start and end by that id, and `stop()` for stopSpeaking.

/// Speaks the home-language translation into the AirPods with the best voice on the device.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Slightly faster than default to keep up with the conversation
    private let rate: Float = 0.54

    /// Ids of the queued utterances; the warm-up utterance has none
    private var ids: [ObjectIdentifier: Int64] = [:]

    /// Called with the utterance id when it starts, and when it finishes or is cancelled
    var onStart: ((Int64) -> Void)?
    var onEnd: ((Int64) -> Void)?

    /// `language` is a language code or locale identifier ("vi", "vi-VN")
    init(language: String) {
        synthesizer.usesApplicationAudioSession = true
        voice = Self.bestVoice(language)
        super.init()
        synthesizer.delegate = self
    }

    /// The highest-quality installed voice for the language, or nil
    static func bestVoice(_ language: String) -> AVSpeechSynthesisVoice? {
        let code = EngineMapping.languageCode(Locale(identifier: language))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { EngineMapping.languageCode(Locale(identifier: $0.language)) == code }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Diag.log("tts: start \"\(u.speechString.prefix(40))\"")
        let key = ObjectIdentifier(u)
        Task { @MainActor in
            if let id = self.ids[key] { self.onStart?(id) }
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
        if let id = ids.removeValue(forKey: key) { onEnd?(id) }
    }

    func speak(_ text: String, id: Int64) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        ids[ObjectIdentifier(utterance)] = id
        Diag.log("tts: enqueue \(id) (queue \(ids.count)) \"\(text.prefix(40))\"")
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
    }

    var voiceName: String { voice?.name ?? "default" }
}
