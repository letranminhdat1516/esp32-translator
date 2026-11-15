import AVFAudio
import CoreMedia
import os
import Speech

// One recognizer per language, used by AppleVoiceEngine (resolved per locale: SpeechTranscriber, else
// DictationTranscriber) and by the Swift app's ConversationEngine (engine picked by the caller). Events carry the
// length of their audio; hints (contextual strings), asset status and asset installation with progress.

enum TranscriptEvent: Sendable, Equatable {
    /// Volatile result that may still change; each one replaces the previous volatile text.
    /// `audio` is the length of the audio it covers, in seconds.
    case partial(String, audio: TimeInterval = 0)
    /// Finalized phrase, will not change. `confidence` is the mean word confidence (0…1) when the engine reports it.
    case final(String, confidence: Double?, audio: TimeInterval = 0)
}

/// Continuous, fully on-device speech recognition with SpeechAnalyzer (iOS 26).
/// The analyzer runs for the whole session instead of per utterance, so models never reload.
final class LiveTranscriber: @unchecked Sendable {
    enum Engine {
        /// Newest and fastest model; used where it supports the locale
        case speech
        /// Dictation model; covers locales SpeechTranscriber does not (Vietnamese)
        case dictation
    }

    let locale: Locale
    let engine: Engine
    private(set) var audioFormat: AVAudioFormat?
    private let module: any SpeechModule
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Seconds of audio fed so far (diagnostics: lag = fed - result end)
    private let fedSeconds = OSAllocatedUnfairLock(initialState: 0.0)
    /// Started; the results stream ended (an analysis error, which it never recovers from); stopped
    private let lifecycle = OSAllocatedUnfairLock(initialState: (started: false, ended: false, stopped: false))

    /// Started, not stopped, and the analysis has not ended: false for good after a fatal error
    var isAlive: Bool { lifecycle.withLock { $0.started && !$0.ended && !$0.stopped } }

    init(locale: Locale, engine: Engine) {
        self.locale = locale
        self.engine = engine
        module = Self.module(locale: locale, engine: engine)
    }

    private static func module(locale: Locale, engine: Engine) -> any SpeechModule {
        switch engine {
        case .speech:
            SpeechTranscriber(locale: locale, transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .fastResults],
                              attributeOptions: [.transcriptionConfidence])
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [],
                                 transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization],
                                 attributeOptions: [])
        }
    }

    /// The on-device recognizer for a language code or locale identifier ("en", "en-US"): SpeechTranscriber if
    /// it supports it, else DictationTranscriber; nil when neither does
    static func resolve(_ language: String) async -> LiveTranscriber? {
        let wanted = Locale(identifier: language)
        var speech: LiveTranscriber?
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            speech = LiveTranscriber(locale: locale, engine: .speech)
        }
        var dictation: LiveTranscriber?
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            dictation = LiveTranscriber(locale: locale, engine: .dictation)
        }
        // SpeechTranscriber can claim a locale whose model it cannot download (vi_VN on iOS 26.6: status
        // unsupported, install ends "Not Installing"); DictationTranscriber then is the one that works.
        if let s = speech, let d = dictation, await s.assetStatus == .unsupported {
            let dStatus = await d.assetStatus
            Diag.log("transcriber: \(language) speech model unsupported, dictation \(dStatus)")
            if dStatus != .unsupported { return d }
        }
        return speech ?? dictation
    }

    var assetStatus: AssetInventory.Status {
        get async { await AssetInventory.status(forModules: [module]) }
    }

    /// Downloads the speech model if missing (once, then works offline); `progress` gets 0…1
    func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// The same without progress (the Swift app's ConversationEngine, ios/Tools/vi-harness)
    func installAssetsIfNeeded() async throws {
        try await installAssets(progress: { _ in })
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
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal, range: r.range))
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        self.logLag(r.range)
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal, range: r.range))
                    }
                }
                Diag.log("[\(self.locale.identifier)] results stream FINISHED without error")
            } catch {
                Diag.log("[\(self.locale.identifier)] results stream ENDED with error: \(error)")
            }
            // Either way no result will come again: the recognizer is dead until it is rebuilt
            self.lifecycle.withLock { $0.ended = true }
        }
        try await analyzer.start(inputSequence: stream)
        lifecycle.withLock { $0.started = true }
    }

    /// Words the recognizer should expect (names, places, glossary terms). Empty clears them.
    func setHints(_ hints: [String]) async {
        guard let analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings = hints.isEmpty ? [:] : [.general: hints]
        do {
            try await analyzer.setContext(context)
        } catch {
            Diag.log("[\(locale.identifier)] hints not set: \(error)")
        }
    }

    /// Safe to call from the audio thread or any queue
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
        lifecycle.withLock { $0.stopped = true }
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

    private static func event(text: AttributedString, isFinal: Bool, range: CMTimeRange) -> TranscriptEvent {
        let s = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = CMTimeGetSeconds(range.duration)
        let audio = seconds.isFinite ? max(0, seconds) : 0
        guard isFinal else { return .partial(s, audio: audio) }
        // Subscript by attribute type, not `\.transcriptionConfidence`: a key path through the dynamic attribute
        // lookup is not Sendable (strict concurrency warning, an error in Swift 6)
        let confidences = text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
        let mean = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        return .final(s, confidence: mean, audio: audio)
    }
}
