import AVFAudio

/// Speaks the Vietnamese translation into the AirPods with the best voice on the device.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Slightly faster than default to keep up with the conversation
    private let rate: Float = 0.54

    private(set) var queued = 0

    init(language: String = "vi-VN") {
        synthesizer.usesApplicationAudioSession = true
        voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
        super.init()
        synthesizer.delegate = self
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Diag.log("tts: start \"\(u.speechString.prefix(40))\"")
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Diag.log("tts: finish")
        Task { @MainActor in self.queued -= 1 }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Diag.log("tts: cancel")
        Task { @MainActor in self.queued -= 1 }
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        queued += 1
        Diag.log("tts: enqueue (queue \(queued)) \"\(text.prefix(40))\"")
        synthesizer.speak(utterance)
    }

    /// Preloads the voice so the first phrase isn't delayed
    func warmUp() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = voice
        utterance.volume = 0
        queued += 1
        synthesizer.speak(utterance)
    }

    var voiceName: String { voice?.name ?? "default" }
}
