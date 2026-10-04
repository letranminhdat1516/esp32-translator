@preconcurrency import AVFAudio
import ClaudeBoardCore
import Foundation
import Speech

enum SpeechEngineError: Error { case noAudioFormat }

/// The converter's input block runs synchronously inside convert(); it is marked @Sendable by the SDK
private final class OneShot: @unchecked Sendable { var used = false }

/// Converts PCM buffers to `target` (sample rate, channels, sample type). Not thread-safe: one caller at a time.
final class PCMConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let once = OneShot()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if once.used {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.used = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

/// On-device dictation with SpeechAnalyzer + DictationTranscriber (the Vietnamese-capable model), one analyzer
/// per capture; the model stays loaded for the daemon's lifetime.
@available(macOS 26.0, *)
final class SpeechEngine: VoiceEngine, @unchecked Sendable {
    private let locale = Locale(identifier: VoiceConfig.localeIdentifier)

    private func makeModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Speech Recognition permission (asked once; denied → the reason is shown on the board), the locale, and
    /// the model (downloaded once through AssetInventory, then offline).
    func prepare() async -> String? {
        let denied = "Allow Speech Recognition for claude-board in System Settings"
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return denied
        case .notDetermined:
            let status = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            if status == .denied || status == .restricted { return denied }
        default:
            break
        }
        guard await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return "Dictation does not support \(locale.identifier) on this Mac"
        }
        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return "Speech model not installed: \(error.localizedDescription)"
        }
        return nil
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        let module = makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechEngineError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let results = Task<String, Never> {
            var finals: [String] = []
            var volatile = ""
            func joined() -> String { (finals + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ") }
            do {
                for try await r in module.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.isFinal {
                        if !text.isEmpty { finals.append(text) }
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onPartial(joined())
                }
            } catch {}
            return joined()
        }
        try await analyzer.start(inputSequence: stream)
        return SpeechStream(analyzer: analyzer, input: input, results: results, converter: PCMConverter(target: format))
    }
}

@available(macOS 26.0, *)
final class SpeechStream: VoiceStream, @unchecked Sendable {
    /// What the board sends: 16 kHz mono Int16
    static let boardFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                           interleaved: true)!

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<String, Never>
    private let converter: PCMConverter   // VoiceHub (an actor) feeds one packet at a time

    init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, results: Task<String, Never>,
         converter: PCMConverter) {
        self.analyzer = analyzer
        self.input = input
        self.results = results
        self.converter = converter
    }

    func feed(_ samples: [Int16]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.boardFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async -> String {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results.value
    }

    func cancel() async {
        input.finish()
        results.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// `claude-board --transcribe FILE`: the same engine on an audio file, without the board. Checks permission and
/// the model on this Mac; prints partials and the final text exactly as voice would type it.
@available(macOS 26.0, *)
func transcribeFile(_ path: String) async -> Int32 {
    let engine = SpeechEngine()
    if let why = await engine.prepare() {
        print("voice unavailable: \(why)")
        return 1
    }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = PCMConverter(target: SpeechStream.boardFormat)
        let stream = try await engine.begin { print("partial: \($0)") }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            guard let pcm = converter.convert(buffer), let p = pcm.int16ChannelData else { continue }
            stream.feed(Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength))))
        }
        print("final: \(VoiceText.forTyping(await stream.finish()))")
        return 0
    } catch {
        print("transcribe failed: \(error)")
        return 1
    }
}
