import AVFAudio
import Foundation
import Speech
@testable import TranslatorCore

// Fakes for the engine's device pieces, so AppleVoiceEngine and RecognizerPair run on the Mac without a mic,
// speech models or an audio session.

struct FakeFailure: Error {}

/// A recognizer whose `start` can be held open, to suspend `RecognizerPair.start` at a chosen await
final class FakeRecognizer: Recognizer, @unchecked Sendable {
    let locale: Locale
    var audioFormat: AVAudioFormat? { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) }
    private let lock = NSLock()
    private var onEvent: (@Sendable (TranscriptEvent) -> Void)?
    private var gate: CheckedContinuation<Void, Never>?
    private let holdStart: Bool
    private(set) var started = false
    private(set) var stopped = false
    private(set) var entered = false
    private var _fedFrames = 0
    private var _finalized = 0
    private var _hints: [[String]] = []

    init(_ language: String, holdStart: Bool = false) {
        locale = Locale(identifier: language)
        self.holdStart = holdStart
    }

    var assetStatus: AssetInventory.Status { get async { .installed } }

    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        lock.withLock { self.onEvent = onEvent; entered = true }
        if holdStart {
            await withCheckedContinuation { c in lock.withLock { gate = c } }
        }
        lock.withLock { started = true }
    }

    /// Lets a held `start` return
    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }
        c?.resume()
    }

    var isHeld: Bool { lock.withLock { gate != nil } }
    var fedFrames: Int { lock.withLock { _fedFrames } }
    var finalized: Int { lock.withLock { _finalized } }
    var hints: [[String]] { lock.withLock { _hints } }

    func emit(_ event: TranscriptEvent) { lock.withLock { onEvent }?(event) }

    func setHints(_ hints: [String]) async { lock.withLock { _hints.append(hints) } }
    func feed(_ buffer: AVAudioPCMBuffer) { lock.withLock { _fedFrames += Int(buffer.frameLength) } }
    func finalizeNow() { lock.withLock { _finalized += 1 } }
    func stop() async { lock.withLock { stopped = true } }

    private var failed = false
    /// Running: started, not stopped, and no fatal error
    var isAlive: Bool { lock.withLock { started && !stopped && !failed } }
    /// Simulates the analysis ending with an error (it will not resume)
    func failFatally() { lock.withLock { failed = true } }
}

/// Every call to the fake session and speaker, in order
@MainActor
final class CallLog {
    var calls: [String] = []
}

@MainActor
final class FakeSession: EngineAudioSession {
    let log: CallLog
    var onChange: ((AudioSessionChange) -> Void)?
    var currentRoute: AudioRoute = .headset
    var failConfigure = false

    init(log: CallLog) { self.log = log }

    func configureForConversation() throws {
        log.calls.append("session.configure")
        if failConfigure { throw FakeFailure() }
    }
    func stopSilence() { log.calls.append("session.stopSilence") }
    func deactivate() { log.calls.append("session.deactivate") }
    func startSilence() { log.calls.append("session.startSilence") }
    func release() { log.calls.append("session.release") }
}

@MainActor
final class FakeSpeaker: EngineSpeaker {
    let log: CallLog
    let language: String
    var onStart: ((Int) -> Void)?
    var onEnd: ((Int) -> Void)?
    var voiceName: String { "fake" }
    private(set) var spoken: [(String, Int)] = []

    init(language: String, log: CallLog) {
        self.language = language
        self.log = log
    }

    func speak(_ text: String, id: Int) {
        log.calls.append("speaker.speak \(id)")
        spoken.append((text, id))
    }
    func stop() { log.calls.append("speaker.stop") }
    func warmUp() { log.calls.append("speaker.warmUp") }
}

final class FakeMic: EngineMic {
    let sink: (AVAudioPCMBuffer) -> Void
    let onSpeechStart: () -> Void
    let onFinalize: () -> Void
    let onSpeechEnd: () -> Void
    private let fail: Bool
    private(set) var started = false
    private(set) var stopped = false

    init(fail: Bool, sink: @escaping (AVAudioPCMBuffer) -> Void, onSpeechStart: @escaping () -> Void,
         onFinalize: @escaping () -> Void, onSpeechEnd: @escaping () -> Void) {
        self.fail = fail
        self.sink = sink
        self.onSpeechStart = onSpeechStart
        self.onFinalize = onFinalize
        self.onSpeechEnd = onSpeechEnd
    }

    func start() throws {
        if fail { throw FakeFailure() }
        started = true
    }
    func stop() { stopped = true }
}

/// An AppleVoiceEngine on fakes, with handles on each fake
@MainActor
final class EngineRig {
    let log = CallLog()
    let session: FakeSession
    var recognizers: [String: [FakeRecognizer]]
    private(set) var speakers: [FakeSpeaker] = []
    private(set) var mics: [FakeMic] = []
    var micFails = false
    var micPermitted = true
    private(set) var translatorsMade: [String] = []
    var translate: @Sendable (String, String, String) async throws -> String = { text, _, to in "\(text)[\(to)]" }
    let capabilityHomes = Locked<[String]>([])
    let missingPairs = Locked<[PairMsg]>([])
    var downloadWork = Downloads.Work(translation: { _, _ in }, speech: { _, _ in }, voice: {})
    private(set) var settingsOpened = 0
    private(set) lazy var engine: AppleVoiceEngine = makeEngine()

    /// `recognizers`: per language, the recognizers handed out in turn (one per start)
    init(_ recognizers: [String: [FakeRecognizer]]) {
        self.recognizers = recognizers
        session = FakeSession(log: log)
    }

    private func makeEngine() -> AppleVoiceEngine {
        let homes = capabilityHomes, pairs = missingPairs
        return AppleVoiceEngine(platform: AppleEnginePlatform(
            session: session,
            makeSpeaker: { [unowned self] language in
                let s = FakeSpeaker(language: language, log: log)
                speakers.append(s)
                return s
            },
            makeMic: { [unowned self] _, _, sink, onStart, onFinalize, onEnd in
                log.calls.append("mic.make")
                let m = FakeMic(fail: micFails, sink: sink, onSpeechStart: onStart, onFinalize: onFinalize,
                                onSpeechEnd: onEnd)
                mics.append(m)
                return m
            },
            micPermitted: { [unowned self] in micPermitted },
            requestMicPermission: {},
            recognizer: { [unowned self] language in
                guard var queue = recognizers[language], !queue.isEmpty else { return nil }
                let r = queue.removeFirst()
                recognizers[language] = queue
                return r
            },
            makeTranslator: { [unowned self] from, to in
                translatorsMade.append("\(from)>\(to)")
                let translate = self.translate
                return { text in try await translate(text, from, to) }
            },
            downloads: downloadWork,
            openSettings: { [unowned self] in settingsOpened += 1 },
            gatherCapabilities: { home in
                homes.mutate { $0.append(home) }
                return CapabilitiesMsg(recognizers: [RecognizerEntryMsg(language: "en", kinds: ["osOnDevice"])],
                                       translatable: ["en", home], vietnameseVoice: true)
            },
            gatherMissing: { pair in
                pairs.mutate { $0.append(pair) }
                return [MissingMsg(kind: .ttsVoice, language: pair.home)]
            }))
    }
}

/// A value shared with `@Sendable` closures
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var get: Value { lock.withLock { value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

/// Records every event of the given subscriptions (made before `init` returns), in arrival order
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEvent] = []
    private var tasks: [Task<Void, Never>] = []

    init(_ e: EngineEvents) {
        pump(e.mine) { .mine($0) }
        pump(e.theirs) { .theirs($0) }
        pump(e.gate) { .gate($0) }
        pump(e.ttsStart) { .ttsStart($0) }
        pump(e.ttsEnd) { .ttsEnd($0) }
        pump(e.audioSession) { .audioSession($0) }
        pump(e.download) { .download($0) }
    }

    convenience init(_ sink: EngineEventSink) {
        self.init(EngineEvents(mine: sink.mine.stream(), theirs: sink.theirs.stream(), gate: sink.gate.stream(),
                               ttsStart: sink.ttsStart.stream(), ttsEnd: sink.ttsEnd.stream(),
                               audioSession: sink.audioSession.stream(), download: sink.download.stream()))
    }

    private func pump<T: Sendable>(_ stream: AsyncStream<T>, _ wrap: @escaping @Sendable (T) -> EngineEvent) {
        tasks.append(Task { [weak self] in
            for await value in stream { self?.append(wrap(value)) }
        })
    }

    private func append(_ event: EngineEvent) { lock.withLock { events.append(event) } }

    var all: [EngineEvent] { lock.withLock { events } }

    deinit { tasks.forEach { $0.cancel() } }
}

/// Lets queued tasks and stream deliveries run. Only before asserting that something did NOT happen: a check
/// that something did happen waits for it with `until`, so a loaded machine cannot make it fail.
func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
}

/// Polls `condition` until it holds, for up to 10 s (then the assertion that follows reports the failure)
@MainActor
func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

/// `until` for nonisolated tests: polls a Sendable condition for up to 10 s
func eventually(_ condition: @Sendable () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

/// The `EngineError` a call throws, nil when it returns
func engineError(_ body: () async throws -> Void) async -> EngineError? {
    do {
        try await body()
        return nil
    } catch let error as EngineError {
        return error
    } catch {
        return nil
    }
}
