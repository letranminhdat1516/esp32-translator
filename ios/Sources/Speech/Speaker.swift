import AVFAudio

/// Speaks the Vietnamese translation into the AirPods with the best voice on the device.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Slightly faster than default to keep up with the conversation
    private let rate: Float = 0.54

    init(language: String = "vi-VN") {
        synthesizer.usesApplicationAudioSession = true
        voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
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
