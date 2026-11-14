// Speech output probe. The app's Engine/Speaker.swift does not compile on macOS (it sets
// AVSpeechSynthesizer.usesApplicationAudioSession, iOS only), so this mirrors its utterance setup exactly:
// EngineMapping.bestVoice (app code), rate 0.54, no pre/post delay, and the same volume-0 warm-up.
//   speak mode: speak() → delegate didStart (what the app reports as ttsStart; audio is played)
//   write mode: write() → first non-empty PCM buffer (synthesis only, nothing is played)
import AVFAudio
import Foundation

@MainActor
final class TTSProbe: NSObject, AVSpeechSynthesizerDelegate {
    enum Mode: String { case speak, write }
    let mode: Mode
    private let synthesizer = AVSpeechSynthesizer()
    let voice: AVSpeechSynthesisVoice?
    private let rate: Float = 0.54
    private let volume: Float
    /// Utterance → (id, start callback)
    private var pending: [ObjectIdentifier: (Int, (Double) -> Void)] = [:]
    private var finishWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private(set) var busy = 0

    init(mode: Mode, volume: Float) {
        self.mode = mode
        self.volume = volume
        voice = EngineMapping.bestVoice("vi-VN") ?? AVSpeechSynthesisVoice(language: "vi-VN")
        super.init()
        synthesizer.delegate = self
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.volume = volume
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        return u
    }

    /// Speaker.warmUp: a silent " " so the first phrase isn't delayed
    func warmUp() {
        let u = AVSpeechUtterance(string: " ")
        u.voice = voice
        u.volume = 0
        synthesizer.speak(u)
    }

    /// Queues `text`; `onAudio` gets the time (`now()`) its audio starts. Returns when it is queued (as
    /// Speaker.speak); `finished` returns once it has played (speak mode) or been synthesized (write mode).
    @discardableResult
    func speak(_ text: String, onAudio: @escaping (Double) -> Void) -> AVSpeechUtterance {
        let u = utterance(text)
        busy += 1
        switch mode {
        case .speak:
            pending[ObjectIdentifier(u)] = (0, onAudio)
            synthesizer.speak(u)
        case .write:
            var first = true
            let key = ObjectIdentifier(u)
            synthesizer.write(u) { [weak self] buffer in
                let t = now()
                let pcm = buffer as? AVAudioPCMBuffer
                if first, let pcm, pcm.frameLength > 0 {
                    first = false
                    Task { @MainActor in onAudio(t) }
                }
                if pcm == nil || pcm!.frameLength == 0 {
                    // The empty buffer marks the end of the utterance
                    Task { @MainActor in self?.done(key) }
                }
            }
        }
        return u
    }

    func finished(_ u: AVSpeechUtterance) async {
        await withCheckedContinuation { c in finishWaiters[ObjectIdentifier(u)] = c }
    }

    private var doneKeys: Set<ObjectIdentifier> = []
    private func done(_ key: ObjectIdentifier) {
        busy -= 1
        if let c = finishWaiters.removeValue(forKey: key) { c.resume() } else { doneKeys.insert(key) }
    }

    func waitFinished(_ u: AVSpeechUtterance) async {
        let key = ObjectIdentifier(u)
        if doneKeys.remove(key) != nil { return }
        await finished(u)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let t = now()
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.pending.removeValue(forKey: key)?.1(t) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        let warm = u.speechString == " "
        Task { @MainActor in if !warm { self.done(key) } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.done(key) }
    }
}
