import AVFAudio
import CoreMedia
import os
import Speech

enum TranscriptEvent: Sendable {
    /// Volatile result that may still change; each one replaces the previous volatile text
    case partial(String)
    /// Finalized phrase, will not change
    case final(String)
}

/// Continuous, fully on-device speech recognition with SpeechAnalyzer (iOS 26).
/// The analyzer runs for the whole session instead of per utterance, so models never reload.
final class LiveTranscriber: @unchecked Sendable {
    enum Engine {
        /// Newest and fastest model; used for English
        case speech
        /// Dictation model; the only one that supports Vietnamese
        case dictation
    }

    let locale: Locale
    private(set) var audioFormat: AVAudioFormat?
    private let module: any SpeechModule
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Seconds of audio fed so far (diagnostics: lag = fed - result end)
    private let fedSeconds = OSAllocatedUnfairLock(initialState: 0.0)

    init(locale: Locale, engine: Engine) {
        self.locale = locale
        switch engine {
        case .speech:
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults],
                                       attributeOptions: [])
        case .dictation:
            module = DictationTranscriber(locale: locale, contentHints: [],
                                          transcriptionOptions: [.punctuation],
                                          reportingOptions: [.volatileResults, .frequentFinalization],
                                          attributeOptions: [])
        }
    }

    /// Downloads the speech model if missing (once, then works offline)
    func installAssetsIfNeeded() async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        audioFormat = format
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        input = continuation
        self.analyzer = analyzer

        resultsTask = Task { [module] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results {
                        self.logLag(r.range)
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        self.logLag(r.range)
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                }
                Diag.log("[\(self.locale.identifier)] results stream FINISHED without error")
            } catch {
                Diag.log("[\(self.locale.identifier)] results stream ENDED with error: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Safe to call from the audio thread or the BLE queue
    func feed(_ buffer: AVAudioPCMBuffer) {
        Diag.count("feed.\(locale.identifier)", Int(buffer.frameLength))
        Diag.count("rms.\(locale.identifier)", Self.rmsMilli(buffer))
        Diag.count("bufs.\(locale.identifier)")
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        fedSeconds.withLock { $0 += seconds }
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Finalizes everything fed so far. Called when speech ends: input pauses during silence, and without
    /// this the recognizer would hold the last phrase as volatile until the next utterance arrives.
    func finalizeNow() {
        Task { [analyzer] in
            try? await analyzer?.finalize(through: nil)
        }
    }

    func stop() async {
        input?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    var fed: Double { fedSeconds.withLock { $0 } }

    private func logLag(_ range: CMTimeRange) {
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        Diag.log(String(format: "[%@] result audio end %.2fs, fed %.2fs, LAG %.2fs", locale.identifier, end, fed, fed - end))
    }

    /// RMS of a buffer in thousandths of full scale (summed per 5 s window, divided by buffer count in stats)
    private static func rmsMilli(_ buffer: AVAudioPCMBuffer) -> Int {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum = 0.0
        if let p = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
        } else if let p = buffer.floatChannelData?[0] {
            for i in 0..<n { let v = Double(p[i]); sum += v * v }
        }
        return Int((sum / Double(n)).squareRoot() * 1000)
    }

    private static func event(text: AttributedString, isFinal: Bool) -> TranscriptEvent {
        let s = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return isFinal ? .final(s) : .partial(s)
    }
}
