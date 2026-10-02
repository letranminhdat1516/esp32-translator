import AVFAudio

/// Đọc bản dịch tiếng Việt vào AirPods bằng giọng tốt nhất có trên máy.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Nhanh hơn mặc định một chút để theo kịp hội thoại
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

    /// Nạp sẵn giọng đọc để câu đầu tiên không bị chậm
    func warmUp() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    var voiceName: String { voice?.name ?? "mặc định" }
}
