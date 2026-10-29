import Foundation

// Port of app/lib/engine/fake_voice_engine.dart.

/// In-memory `VoiceEngine` for tests: every response is scriptable, every call is recorded, and tests push events
/// with the `emit…` functions (synchronous, from any context).
actor FakeVoiceEngine: VoiceEngine {
    var capabilitiesResult: Capabilities
    /// Returned by `missing(pair:)`.
    var missingResult: [MissingMsg] = []
    /// Translations by source text. A text with no entry is returned unchanged.
    var translations: [String: String] = [:]

    // Recorded calls, in order.
    private(set) var capabilitiesHomes: [String] = []
    private(set) var missingPairs: [PairMsg] = []
    private(set) var spoken: [(text: String, id: Int)] = []
    private(set) var downloaded: [MissingMsg] = []
    private(set) var starts: [(pair: PairMsg, recognizerX: String, hints: [String])] = []
    private(set) var fed: [(pcm: [Int16], sampleRate: Int)] = []
    private(set) var micStates: [Bool] = []
    private(set) var hints: [String] = []
    private(set) var stopCount = 0
    private(set) var stopSpeakingCount = 0
    private(set) var openTtsSettingsCount = 0

    private var failTranslate = false

    init(capabilities: Capabilities = Capabilities(recognizers: [:], translatable: [], vietnameseVoice: true)) {
        capabilitiesResult = capabilities
    }

    // MARK: Scripting

    func setCapabilities(_ capabilities: Capabilities) { capabilitiesResult = capabilities }
    func setMissing(_ missing: [MissingMsg]) { missingResult = missing }
    func setTranslation(_ translation: String, for text: String) { translations[text] = translation }
    /// Makes the next `translate` throw `EngineError.translateFailed`.
    func failNextTranslate() { failTranslate = true }

    // MARK: Events

    private nonisolated let mineEvents = Broadcast<MineMsg>()
    private nonisolated let theirsEvents = Broadcast<TheirsMsg>()
    private nonisolated let gateEvents = Broadcast<Bool>()
    private nonisolated let ttsStartEvents = Broadcast<Int>()
    private nonisolated let ttsEndEvents = Broadcast<Int>()
    private nonisolated let audioSessionEvents = Broadcast<AudioSessionMsg>()
    private nonisolated let downloadEvents = Broadcast<DownloadMsg>()

    nonisolated func emitMine(_ msg: MineMsg) { mineEvents.send(msg) }
    nonisolated func emitTheirs(_ msg: TheirsMsg) { theirsEvents.send(msg) }
    nonisolated func emitGate(_ open: Bool) { gateEvents.send(open) }
    nonisolated func emitTtsStart(_ id: Int) { ttsStartEvents.send(id) }
    nonisolated func emitTtsEnd(_ id: Int) { ttsEndEvents.send(id) }
    nonisolated func emitAudioSession(_ msg: AudioSessionMsg) { audioSessionEvents.send(msg) }
    nonisolated func emitDownload(_ msg: DownloadMsg) { downloadEvents.send(msg) }

    nonisolated var mine: AsyncStream<MineMsg> { mineEvents.stream() }
    nonisolated var theirs: AsyncStream<TheirsMsg> { theirsEvents.stream() }
    nonisolated var gate: AsyncStream<Bool> { gateEvents.stream() }
    nonisolated var ttsStart: AsyncStream<Int> { ttsStartEvents.stream() }
    nonisolated var ttsEnd: AsyncStream<Int> { ttsEndEvents.stream() }
    nonisolated var audioSession: AsyncStream<AudioSessionMsg> { audioSessionEvents.stream() }
    nonisolated var download: AsyncStream<DownloadMsg> { downloadEvents.stream() }

    // MARK: VoiceEngine

    func capabilities(home: String) async throws -> Capabilities {
        capabilitiesHomes.append(home)
        return capabilitiesResult
    }

    func missing(pair: PairMsg) async throws -> [MissingMsg] {
        missingPairs.append(pair)
        return missingResult
    }

    func downloadItem(_ item: MissingMsg) async throws { downloaded.append(item) }

    func start(pair: PairMsg, recognizerX: String, hints: [String]) async throws {
        starts.append((pair: pair, recognizerX: recognizerX, hints: hints))
    }

    func stop() async throws { stopCount += 1 }

    func micOn(_ on: Bool) async throws { micStates.append(on) }

    func feedTheirAudio(_ pcm: [Int16], sampleRate: Int) async throws {
        fed.append((pcm: pcm, sampleRate: sampleRate))
    }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        if failTranslate {
            failTranslate = false
            throw EngineError.translateFailed
        }
        return translations[text] ?? text
    }

    func speak(_ text: String, id: Int) async throws { spoken.append((text: text, id: id)) }

    func stopSpeaking() async throws { stopSpeakingCount += 1 }

    func setHints(_ hints: [String]) async throws { self.hints = hints }

    func openTtsSettings() async throws { openTtsSettingsCount += 1 }
}
