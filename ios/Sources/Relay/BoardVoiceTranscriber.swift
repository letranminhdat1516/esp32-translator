import AVFAudio
import Foundation
import Speech

/// On-device Vietnamese dictation of the board's voice capture while it is relayed (same model and options as the
/// Mac's SpeechEngine: mac/Sources/claude-board/SpeechEngine.swift). One analyzer per capture; the model stays
/// loaded. Not thread-safe: VoiceWorker calls it from one task, in order.
final class BoardVoiceTranscriber: @unchecked Sendable {
    private let locale = Locale(identifier: "vi-VN")
    private static let boardFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                                   interleaved: true)!
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Never>?
    private var decoder = ADPCMDecoder()
    private var converter: BufferConverter?

    private func makeModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// nil when ready; else why not (sent to the Mac, which shows it on the board)
    func prepare() async -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return "Allow Speech Recognition for Live Translator on the iPhone"
        case .notDetermined:
            let s = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            if s != .authorized { return "Allow Speech Recognition for Live Translator on the iPhone" }
        default:
            break
        }
        guard await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return "Vietnamese dictation is not available on this iPhone"
        }
        do {
            if try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) != nil {
                return "Open Live Translator once to install the Vietnamese speech model"
            }
        } catch {
            return "Speech model check failed on the iPhone"
        }
        return nil
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws {
        await cancel()
        let module = makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CocoaError(.featureUnsupported)
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
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        self.analyzer = analyzer
        self.input = input
        self.results = results
        decoder.reset()
        converter = BufferConverter(target: format)
    }

    func feed(_ packet: Data) {
        guard let input, let converter else { return }
        let samples = decoder.decode(packet)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.boardFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async -> String {
        guard let analyzer, let input, let results else { return "" }
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = await results.value
        clear()
        return text
    }

    func cancel() async {
        input?.finish()
        results?.cancel()
        await analyzer?.cancelAndFinishNow()
        clear()
    }

    private func clear() {
        analyzer = nil
        input = nil
        results = nil
        converter = nil
    }
}

/// Runs the transcriber's commands strictly in order on one task (begin is async; packets arrive meanwhile).
/// A failed start (e.g. no room for a third analyzer next to the translator's two) is reported as `failed`, which
/// the relay sends to the Mac as voiceFailed; the translator's analyzers are not touched.
final class VoiceWorker: @unchecked Sendable {
    enum Command: Sendable { case begin(UInt32), feed(Data), finish(UInt32), cancel }
    enum Event: Sendable { case partial(UInt32, String), final(UInt32, String), failed(UInt32, String) }

    /// Set once, before the first command
    var onEvent: (@Sendable (Event) -> Void)? {
        get { sink.handler }
        set { sink.handler = newValue }
    }
    private let sink = Sink()
    private let transcriber = BoardVoiceTranscriber()
    private let commands: AsyncStream<Command>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        Task { [transcriber, sink] in   // ends when the worker goes (deinit finishes the stream)
            var session: UInt32?
            for await command in stream {
                switch command {
                case .begin(let s):
                    do {
                        try await transcriber.begin { text in sink.handler?(.partial(s, text)) }
                        session = s
                    } catch {
                        Diag.log("relay: board voice transcriber did not start: \(error)")
                        session = nil
                        sink.handler?(.failed(s, "Transcription did not start on the iPhone"))
                    }
                case .feed(let p):
                    if session != nil { transcriber.feed(p) }
                case .finish(let s):
                    guard session == s else { continue }
                    let text = await transcriber.finish()
                    session = nil
                    sink.handler?(.final(s, text))
                case .cancel:
                    session = nil
                    await transcriber.cancel()
                }
            }
            await transcriber.cancel()
        }
    }

    deinit { commands.finish() }

    func send(_ command: Command) { commands.yield(command) }
    func prepare() async -> String? { await transcriber.prepare() }

    private final class Sink: @unchecked Sendable {
        var handler: (@Sendable (Event) -> Void)?
    }
}
