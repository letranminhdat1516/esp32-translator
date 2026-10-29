import Foundation

// Port of app/lib/engine/voice_engine.dart (contract) and the message types of app/lib/engine/engine_api.g.dart.
// The Swift engine is in-process (ARCHITECTURE "Revision 2026-10-29" R3): no channel, no codec; the message types
// keep their Dart names and fields so the Swift, Dart and TypeScript code read the same.

/// Typed failures of the voice engine. `rawValue` is the code the Dart and TypeScript sides use.
enum EngineError: String, Error, CaseIterable, Sendable {
    case translateFailed, notReady, downloadFailed

    init?(code: String) { self.init(rawValue: code) }
}

enum MissingKind: String, Codable, CaseIterable, Sendable {
    case speechModel, translation, ttsVoice
}

/// `interrupted`: the mic is really lost (an interruption ended without resume, or retaking the mic failed); the
/// interruption's begin sends nothing. `resumed`: the engine took a wanted mic back itself after an interruption.
enum AudioSessionKind: String, Codable, CaseIterable, Sendable {
    case interrupted, resumed, routeChanged
}

enum AudioRoute: String, Codable, CaseIterable, Sendable {
    case headset, phoneMic
}

/// `finalText` is the "final" kind (Dart name, kept for the shared fixtures).
enum MineKind: String, Codable, CaseIterable, Sendable {
    case partial, finalText
}

/// Recognizers for one language in wire form: `kinds` carries `RecognizerKind` names.
struct RecognizerEntryMsg: Codable, Hashable, Sendable {
    var language: String
    var kinds: [String]
}

/// Capabilities in wire form (as the Dart and TypeScript engines report them); `toModel()` gives `Capabilities`.
struct CapabilitiesMsg: Codable, Hashable, Sendable {
    var recognizers: [RecognizerEntryMsg]
    var translatable: [String]
    var vietnameseVoice: Bool

    struct UnknownRecognizer: Error, Equatable { let name: String }

    /// Throws `UnknownRecognizer` for a kind name that is not a `RecognizerKind`.
    func toModel() throws -> Capabilities {
        var map: [String: [RecognizerKind]] = [:]
        for entry in recognizers {
            map[entry.language] = try entry.kinds.map { name in
                guard let kind = RecognizerKind(rawValue: name) else { throw UnknownRecognizer(name: name) }
                return kind
            }
        }
        return Capabilities(recognizers: map, translatable: Set(translatable), vietnameseVoice: vietnameseVoice)
    }
}

/// Something that must be downloaded before a pair can run. `from`/`to` are set for `.translation`.
struct MissingMsg: Codable, Hashable, Sendable {
    var kind: MissingKind
    var language: String
    var from: String?
    var to: String?

    init(kind: MissingKind, language: String, from: String? = nil, to: String? = nil) {
        self.kind = kind
        self.language = language
        self.from = from
        self.to = to
    }
}

/// The language pair of a session: `home` is always "vi"; `generation` tags the "their" side (SessionMachine).
struct PairMsg: Codable, Hashable, Sendable {
    var home: String
    var other: String
    var generation: Int
}

/// The user's own speech (TurnAssembler input). Times in ms since the session started.
struct MineMsg: Codable, Hashable, Sendable {
    var kind: MineKind
    var text: String
    var startMs: Int
    var endMs: Int
}

/// A final result of the other person's speech; `confidence` nil when the recognizer gives none.
struct TheirsMsg: Codable, Hashable, Sendable {
    var text: String
    var confidence: Double?
    var generation: Int
}

struct AudioSessionMsg: Codable, Hashable, Sendable {
    var kind: AudioSessionKind
    var route: AudioRoute?

    init(kind: AudioSessionKind, route: AudioRoute? = nil) {
        self.kind = kind
        self.route = route
    }
}

/// Download progress (0...1), completion or failure of one `MissingMsg`.
struct DownloadMsg: Codable, Hashable, Sendable {
    var item: MissingMsg
    var progress: Double
    var done: Bool
    var error: String?
}

/// The one native engine per platform: mic, voice gate, recognizers, offline translation and TTS.
///
/// Calls throw `EngineError` for the failures the caller handles (`translate` → `.translateFailed`, a call before
/// `start` → `.notReady`, `downloadItem` → `.downloadFailed`); other errors are passed through unchanged.
///
/// Events are broadcast: every access to an event property returns a new `AsyncStream` that receives every event
/// sent after that access (like the Dart broadcast streams).
///
/// Subscribing inside a Task is a race: in `Task { for await x in engine.ttsStart { … } }` the property is read only
/// when the Task first runs, so events sent before that are lost. Call `events()` first (it subscribes to every stream
/// synchronously) and hand its streams to the Task: `let ev = engine.events(); Task { for await x in ev.ttsStart … }`.
protocol VoiceEngine: AnyObject, Sendable {
    /// Fast, no downloads; called at launch and after any download. `home` is the user's language ("vi").
    func capabilities(home: String) async throws -> Capabilities
    func missing(pair: PairMsg) async throws -> [MissingMsg]
    /// The `download` call (Dart name: the `download` event takes the plain name). Progress arrives on `download`.
    func downloadItem(_ item: MissingMsg) async throws
    /// Idempotent. `recognizerX` is a `RecognizerKind` raw value for the other language.
    func start(pair: PairMsg, recognizerX: String, hints: [String]) async throws
    func stop() async throws
    func micOn(_ on: Bool) async throws
    /// PCM from the board, 16-bit mono.
    /// Throws `EngineError.notReady` while the other-language recognizer is not running (never started, stopped, or died) until the next successful `start`.
    func feedTheirAudio(_ pcm: [Int16], sampleRate: Int) async throws
    /// Throws `EngineError.translateFailed` on failure; the caller decides the fallback.
    func translate(_ text: String, from: String, to: String) async throws -> String
    /// `ttsStart(id)` and `ttsEnd(id)` follow.
    func speak(_ text: String, id: Int) async throws
    func stopSpeaking() async throws
    /// No-op where unsupported.
    func setHints(_ hints: [String]) async throws
    func openTtsSettings() async throws

    var mine: AsyncStream<MineMsg> { get }
    var theirs: AsyncStream<TheirsMsg> { get }
    /// Voice gate open (true) / closed (false), for ConversationActivity.
    var gate: AsyncStream<Bool> { get }
    var ttsStart: AsyncStream<Int> { get }
    var ttsEnd: AsyncStream<Int> { get }
    var audioSession: AsyncStream<AudioSessionMsg> { get }
    var download: AsyncStream<DownloadMsg> { get }
}

/// One subscription to every `VoiceEngine` event stream, all made before `events()` returns.
struct EngineEvents: Sendable {
    let mine: AsyncStream<MineMsg>
    let theirs: AsyncStream<TheirsMsg>
    let gate: AsyncStream<Bool>
    let ttsStart: AsyncStream<Int>
    let ttsEnd: AsyncStream<Int>
    let audioSession: AsyncStream<AudioSessionMsg>
    let download: AsyncStream<DownloadMsg>
}

extension VoiceEngine {
    /// Subscribes to all seven event streams now (synchronously); see the race note on `VoiceEngine`.
    func events() -> EngineEvents {
        EngineEvents(mine: mine, theirs: theirs, gate: gate, ttsStart: ttsStart, ttsEnd: ttsEnd,
                     audioSession: audioSession, download: download)
    }
}

/// Fan-out of events to any number of `AsyncStream` subscribers; thread safe. Used by engines and board links to
/// give each event property broadcast semantics.
final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    /// `bufferingPolicy` applies to each subscriber's unread elements (e.g. `.bufferingNewest(64)` for audio).
    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }

    /// A new subscription: receives every element sent after this call, until the stream is dropped or `finish()`.
    /// After `finish()` the stream is already finished.
    func stream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            let added = lock.withLock { () -> Bool in
                guard !finished else { return false }
                continuations[id] = continuation
                return true
            }
            guard added else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ element: Element) {
        for continuation in lock.withLock({ Array(continuations.values) }) {
            continuation.yield(element)
        }
    }

    /// Ends every subscription, current and future; later `send`s are dropped.
    func finish() {
        let ending = lock.withLock { () -> [AsyncStream<Element>.Continuation] in
            finished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in ending { continuation.finish() }
    }
}
