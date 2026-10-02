import AVFAudio
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
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                }
            } catch {
                print("[\(self.locale.identifier)] results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Safe to call from the audio thread or the BLE queue
    func feed(_ buffer: AVAudioPCMBuffer) {
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() async {
        input?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private static func event(text: AttributedString, isFinal: Bool) -> TranscriptEvent {
        let s = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return isFinal ? .final(s) : .partial(s)
    }
}
