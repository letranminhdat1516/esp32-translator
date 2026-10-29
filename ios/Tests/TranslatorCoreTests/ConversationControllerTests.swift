import Foundation
import Testing
@testable import TranslatorCore

// ConversationController (P2.2) against FakeVoiceEngine + FakeBoardLink and a scripted translator: the behavioural
// spec is the Flutter plan's P2.1 brief and ARCHITECTURE §2, §3 and §6.

// MARK: - Test doubles

/// A time source the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Opens once; every `wait()` before that suspends.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func open() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for c in ready { c.resume() }
    }
}

/// `FakeVoiceEngine` with a scripted translator (`[to]text` by default), a board recognizer that can die (its
/// `feedTheirAudio` throws) and per-call failures. Everything else is the fake's.
final class ScriptedEngine: VoiceEngine, @unchecked Sendable {
    typealias Translate = @Sendable (_ text: String, _ from: String, _ to: String) async throws -> String

    let fake: FakeVoiceEngine
    private let lock = NSLock()
    private var _translate: Translate = { text, _, to in "[\(to)]\(text)" }
    private var _calls: [(text: String, from: String, to: String)] = []
    private var _feedFails = false

    init(_ fake: FakeVoiceEngine) { self.fake = fake }

    func script(_ translate: @escaping Translate) { lock.withLock { _translate = translate } }
    var translateCalls: [(text: String, from: String, to: String)] { lock.withLock { _calls } }
    /// From now on `feedTheirAudio` throws (the board recognizer is dead).
    func killTheirRecognizer(_ dead: Bool = true) { lock.withLock { _feedFails = dead } }

    func capabilities(home: String) async throws -> Capabilities { try await fake.capabilities(home: home) }
    func missing(pair: PairMsg) async throws -> [MissingMsg] { try await fake.missing(pair: pair) }
    func downloadItem(_ item: MissingMsg) async throws { try await fake.downloadItem(item) }
    func start(pair: PairMsg, recognizerX: String, hints: [String]) async throws {
        try await fake.start(pair: pair, recognizerX: recognizerX, hints: hints)
    }
    func stop() async throws { try await fake.stop() }
    func micOn(_ on: Bool) async throws { try await fake.micOn(on) }
    func feedTheirAudio(_ pcm: [Int16], sampleRate: Int) async throws {
        if lock.withLock({ _feedFails }) { throw EngineError.notReady }
        try await fake.feedTheirAudio(pcm, sampleRate: sampleRate)
    }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        let t = lock.withLock { () -> Translate in
            _calls.append((text, from, to))
            return _translate
        }
        return try await t(text, from, to)
    }
    func speak(_ text: String, id: Int) async throws { try await fake.speak(text, id: id) }
    func stopSpeaking() async throws { try await fake.stopSpeaking() }
    func setHints(_ hints: [String]) async throws { try await fake.setHints(hints) }
    func openTtsSettings() async throws { try await fake.openTtsSettings() }

    var mine: AsyncStream<MineMsg> { fake.mine }
    var theirs: AsyncStream<TheirsMsg> { fake.theirs }
    var gate: AsyncStream<Bool> { fake.gate }
    var ttsStart: AsyncStream<Int> { fake.ttsStart }
    var ttsEnd: AsyncStream<Int> { fake.ttsEnd }
    var audioSession: AsyncStream<AudioSessionMsg> { fake.audioSession }
    var download: AsyncStream<DownloadMsg> { fake.download }
}

/// Polls `condition` (every 5 ms, up to 3 s): the controller works through its event streams asynchronously.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(3)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Lets queued work run, for "nothing happens" checks.
@MainActor
func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
final class Rig {
    let fake: FakeVoiceEngine
    let engine: ScriptedEngine
    let board = FakeBoardLink()
    let clock = TestClock()
    let ui = UIState()
    let defaults: UserDefaults
    let glossary: GlossaryStore?
    let controller: ConversationController

    nonisolated static let allCaps = Capabilities(recognizers: ["en": [.osOnDevice], "ja": [.osOnDevice], "vi": [.osOnDevice]],
                                      translatable: ["en", "ja", "vi"], vietnameseVoice: true)

    init(caps: Capabilities = Rig.allCaps, missing: [MissingMsg] = [], defaults: UserDefaults? = nil,
         glossaryDirectory: URL? = nil) async throws {
        fake = FakeVoiceEngine(capabilities: caps)
        await fake.setMissing(missing)
        engine = ScriptedEngine(fake)
        self.defaults = defaults ?? Rig.freshDefaults()
        glossary = glossaryDirectory.map { GlossaryStore(directory: $0) }
        let packs = try ["vi", "en", "ja"].map { try Fixtures.pack($0) }
        let clock = self.clock
        controller = ConversationController(engine: engine, board: board, packs: packs, glossary: glossary,
                                            defaults: self.defaults, boardText: BoardText(glyphs: BoardGlyphSets()),
                                            ui: ui, now: { clock.now })
    }

    static func freshDefaults() -> UserDefaults {
        let name = "ConversationControllerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func startRunning(_ code: String = "en") async -> Bool {
        await controller.start()
        return await eventually { [ui] in ui.session == .running(code) }
    }

    func spoken() async -> [String] { await fake.spoken.map(\.text) }
    func sent(_ kind: TextKind) -> [String] { board.sentTexts.filter { $0.kind == kind }.map(\.text) }

    func mine(_ text: String, final: Bool) {
        fake.emitMine(MineMsg(kind: final ? .finalText : .partial, text: text, startMs: 0, endMs: 0))
    }

    func theirs(_ text: String, confidence: Double? = 0.9, generation: Int = 0) {
        fake.emitTheirs(TheirsMsg(text: text, confidence: confidence, generation: generation))
    }

    /// One ADPCM packet from the board: [seq u16][predictor i16][index u8][data] → 2 samples per data byte.
    func boardAudio(seq: UInt16 = 0) {
        board.emitAudio(Data([UInt8(seq & 0xFF), UInt8(seq >> 8), 0, 0, 0, 0x11, 0x22]))
    }

    deinit {
        let fake = fake, board = board
        fake.finishEvents()
        board.finishEvents()
    }
}

// MARK: - Tests

@Suite(.serialized) @MainActor
struct ConversationControllerTests {
    @Test func fullConversationBothDirections() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        // Default pick is English, home is Vietnamese
        #expect(await rig.fake.capabilitiesHomes == ["vi"])
        let start = try #require(await rig.fake.starts.first)
        #expect(start.pair == PairMsg(home: "vi", other: "en", generation: 0))
        #expect(start.recognizerX == RecognizerKind.osOnDevice.rawValue)
        #expect(rig.ui.languageCode == "en")
        #expect(rig.ui.languageLabel == "English")
        #expect(rig.ui.offeredPacks.map(\.code).sorted() == ["en", "ja"])
        // Opening the app starts a conversation: the mic is taken
        #expect(await eventually { await rig.fake.micStates == [true] })
        #expect(rig.ui.listening)

        // Their side: board audio → decoded PCM → recognizer; the final phrase is translated and spoken
        rig.boardAudio()
        #expect(await eventually { await rig.fake.fed.count == 1 })
        let fed = try #require(await rig.fake.fed.first)
        #expect(fed.sampleRate == 16_000)
        #expect(fed.pcm.count == 4)
        rig.theirs("Hello there")
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there"] })
        #expect(await rig.fake.spoken.map(\.id) == [1])
        #expect(rig.ui.lines.contains { !$0.mine && $0.source == "Hello there" && $0.target == "[vi]Hello there" })

        // My side: partial → final → subtitle on the board
        rig.clock.advance(5)
        rig.mine("tôi muốn", final: false)
        #expect(await eventually { rig.ui.myPartial == "tôi muốn" })
        rig.mine("tôi muốn ăn phở", final: true)
        #expect(await eventually { rig.sent(.subtitle).last == "[en]tôi muốn ăn phở" })
        #expect(rig.ui.myPartial == "")
        #expect(rig.ui.lines.contains { $0.mine && $0.source == "tôi muốn ăn phở" && $0.target == "[en]tôi muốn ăn phở" })
        #expect(rig.engine.translateCalls.contains { $0.from == "vi" && $0.to == "en" })

        // Phrases keep their strict order and ids
        rig.clock.advance(5)
        rig.theirs("One")
        rig.theirs("Two")
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there", "[vi]One", "[vi]Two"] })
        #expect(await rig.fake.spoken.map(\.id) == [1, 2, 3])

        // Stop listening gives the mic back; clear empties the screen and the board
        rig.ui.startStop()
        #expect(await eventually { await rig.fake.micStates == [true, false] })
        #expect(!rig.ui.listening)
        rig.ui.clear()
        #expect(rig.ui.lines.isEmpty)
        #expect(await eventually { rig.sent(.subtitle).last == "" })
        rig.controller.shutdown()
    }

    @Test func theirSpeechIsDroppedWhileIAmSpeaking() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.mine("tôi đang nói", final: false)
        #expect(await eventually { rig.ui.myPartial == "tôi đang nói" })
        rig.theirs("echo of me")
        await settle()
        #expect(await rig.spoken().isEmpty)
        rig.controller.shutdown()
    }

    @Test func lowConfidenceIsShownDimmedWithOneCue() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.theirs("mumble", confidence: 0.1)
        #expect(await eventually { rig.ui.lines.contains { $0.unclear && $0.source == "mumble" } })
        #expect(await eventually { await rig.spoken() == [ConversationController.unclearCue] })
        rig.clock.advance(1)
        rig.theirs("mumble again", confidence: 0.1)
        #expect(await eventually { rig.ui.lines.filter(\.unclear).count == 2 })
        await settle()
        #expect(await rig.spoken() == [ConversationController.unclearCue])
        #expect(!rig.engine.translateCalls.contains { $0.text.contains("mumble") })
        rig.controller.shutdown()
    }

    /// Review Focus 2: a language switch while translations are queued for speech; nothing of the old pair is spoken
    /// after the switch.
    @Test func switchDropsOldGenerationAndSpeaksNothingOld() async throws {
        let rig = try await Rig()
        let latch = Latch()
        rig.engine.script { text, _, to in
            if text == "first" { await latch.wait() }
            return "[\(to)]\(text)"
        }
        #expect(await rig.startRunning())
        rig.theirs("first")
        rig.theirs("second")
        #expect(await eventually { rig.engine.translateCalls.contains { $0.text == "first" } })

        rig.ui.pickLanguage("ja")
        #expect(await eventually { rig.ui.session == .running("ja") })
        #expect(await rig.fake.stopSpeakingCount >= 1)
        let last = try #require(await rig.fake.starts.last)
        #expect(last.pair == PairMsg(home: "vi", other: "ja", generation: 1))

        latch.open()                       // the old translation finishes after the switch
        rig.theirs("late", generation: 0)  // a late result of the old recognizer
        rig.theirs("konnichiwa", generation: 1)
        #expect(await eventually { await rig.spoken() == ["[vi]konnichiwa"] })
        await settle()
        #expect(await rig.spoken() == ["[vi]konnichiwa"])
        #expect(!rig.engine.translateCalls.contains { $0.text == "second" || $0.text == "late" })
        #expect(!rig.ui.lines.contains { ["first", "second", "late"].contains($0.source) })
        #expect(rig.engine.translateCalls.last.map { ($0.from, $0.to) } ?? ("", "") == ("ja", "vi"))
        rig.controller.shutdown()
    }

    @Test func labelIsSentOnStartOnReadyAndOnSwitch() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        #expect(await eventually { rig.sent(.label) == ["English"] })
        rig.board.emitState(.ready)
        #expect(await eventually { rig.sent(.label) == ["English", "English"] })
        #expect(rig.sent(.time).count == 1)
        #expect(rig.ui.board == .ready)
        // The board has no CJK font: the Latin label goes out
        rig.ui.pickLanguage("ja")
        #expect(await eventually { rig.sent(.label).last == "JA" })
        rig.board.info = BoardInfo(protocolVersion: 1, fontSets: [.latinVI, .latinExtA, .cjk])
        rig.board.emitState(.connecting)
        rig.board.emitState(.ready)
        #expect(await eventually { rig.sent(.label).last == "日本語" })
        #expect(rig.sent(.time).count == 2)
        rig.controller.shutdown()
    }

    @Test func pickPersistsAcrossANewController() async throws {
        let defaults = Rig.freshDefaults()
        let first = try await Rig(defaults: defaults)
        #expect(await first.startRunning())
        first.ui.pickLanguage("ja")
        #expect(await eventually { first.ui.session == .running("ja") })
        first.controller.shutdown()

        let second = try await Rig(defaults: defaults)
        #expect(await second.startRunning("ja"))
        #expect(await second.fake.starts.first?.pair.other == "ja")
        #expect(second.ui.languageLabel == "日本語")
        second.controller.shutdown()
    }

    @Test func savedPickNoLongerOfferedAsksToChoose() async throws {
        let defaults = Rig.freshDefaults()
        defaults.set("ko", forKey: ConversationController.pickKey)
        let rig = try await Rig(defaults: defaults)
        await rig.controller.start()
        #expect(await eventually { rig.ui.session == .choosing(reason: "unavailable") })
        rig.ui.pickLanguage("en")
        #expect(await eventually { rig.ui.session == .running("en") })
        rig.controller.shutdown()
    }

    @Test func missingItemsAreDownloadedThenTheSessionStarts() async throws {
        let item = MissingMsg(kind: .speechModel, language: "en")
        let rig = try await Rig(missing: [item])
        await rig.controller.start()
        #expect(await eventually { rig.ui.session == .needsDownload("en", missing: [item]) })
        #expect(rig.ui.readiness == .needsDownload)
        await rig.fake.setMissing([])
        rig.ui.download()
        #expect(await eventually { rig.ui.session == .running("en") })
        #expect(await rig.fake.downloaded == [item])
        rig.controller.shutdown()
    }

    @Test func theirRecognizerDiesRestartsOnceThenFailsWhileMySideKeepsRunning() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.engine.killTheirRecognizer()
        rig.boardAudio(seq: 1)
        #expect(await eventually { rig.ui.session == .running("en", restarts: 1) })
        #expect(await rig.fake.starts.count == 2)
        #expect(await rig.fake.stopCount == 1)
        // The restart stopped the engine: the conversation takes the mic back
        #expect(await eventually { await rig.fake.micStates == [true, true] })

        rig.boardAudio(seq: 2)
        #expect(await eventually { rig.ui.session == .failed("en", reason: "recognizer stopped") })
        #expect(await rig.fake.starts.count == 2)

        rig.clock.advance(5)
        rig.mine("tôi vẫn nói được", final: true)
        #expect(await eventually { rig.sent(.subtitle).last == "[en]tôi vẫn nói được" })
        rig.controller.shutdown()
    }

    @Test func translatorThrowsTheirPhraseSkippedMySourceKept() async throws {
        let rig = try await Rig()
        rig.engine.script { text, _, to in
            if text == "boom" || text == "tôi đói" { throw EngineError.translateFailed }
            return "[\(to)]\(text)"
        }
        #expect(await rig.startRunning())
        rig.theirs("boom")
        rig.theirs("fine")
        #expect(await eventually { await rig.spoken() == ["[vi]fine"] })
        #expect(!rig.ui.lines.contains { $0.source == "boom" })

        rig.clock.advance(5)
        rig.mine("tôi đói", final: true)
        #expect(await eventually { rig.sent(.subtitle).last == "tôi đói" })
        #expect(rig.ui.lines.contains { $0.mine && $0.target == "tôi đói" })
        rig.controller.shutdown()
    }

    @Test func missingVietnameseVoiceShowsTheBannerAndKeepsText() async throws {
        let caps = Capabilities(recognizers: Rig.allCaps.recognizers, translatable: Rig.allCaps.translatable,
                                vietnameseVoice: false)
        let rig = try await Rig(caps: caps, missing: [MissingMsg(kind: .ttsVoice, language: "vi")])
        #expect(await rig.startRunning())
        #expect(rig.ui.ttsVoiceMissing)
        rig.theirs("Good morning")
        #expect(await eventually { rig.ui.lines.contains { $0.target == "[vi]Good morning" } })
        rig.ui.openTtsSettings()
        #expect(await eventually { await rig.fake.openTtsSettingsCount == 1 })
        rig.controller.shutdown()
    }

    @Test func glossaryAddSetsHintsAndMasksTheNextPhrase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try await Rig(glossaryDirectory: dir)
        #expect(await rig.startRunning())

        #expect(throws: GlossaryValidationError(message: GlossaryMessages.empty)) { try rig.ui.glossaryAdd("  ") }
        try rig.ui.glossaryAdd("Bến Thành")
        #expect(await eventually { await rig.fake.hints.contains("Bến Thành") })
        #expect(rig.ui.glossaryTerms.map(\.text) == ["Bến Thành"])
        #expect(throws: GlossaryValidationError(message: GlossaryMessages.duplicate)) {
            try rig.ui.glossaryAdd("bến thành")
        }

        rig.theirs("Meet me at Bến Thành market")
        #expect(await eventually { await rig.spoken() == ["[vi]Meet me at Bến Thành market"] })
        let sentToTranslator = try #require(rig.engine.translateCalls.last?.text)
        #expect(!sentToTranslator.contains("Bến Thành"))
        #expect(sentToTranslator.contains("Zorvik"))

        let id = try #require(rig.ui.glossaryTerms.first?.id)
        try rig.ui.glossaryUpdate(id, "Chợ Bến Thành")
        #expect(await eventually { rig.ui.glossaryTerms.map(\.text) == ["Chợ Bến Thành"] })
        try rig.ui.glossaryDelete(id)
        #expect(await eventually { rig.ui.glossaryTerms.isEmpty })
        rig.controller.shutdown()
    }

    @Test func boardAbsentShowsNoBoardWhileThePhoneSideWorks() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        #expect(rig.ui.board == .off)
        #expect(await eventually { rig.ui.listening })
        #expect(rig.ui.chips.contains(.noBoard))
        rig.mine("xin chào", final: true)
        #expect(await eventually { rig.ui.lines.contains { $0.mine && $0.target == "[en]xin chào" } })
        rig.clock.advance(5)  // past the echo hold after my words
        rig.theirs("Hi")
        #expect(await eventually { await rig.spoken() == ["[vi]Hi"] })
        rig.controller.shutdown()
    }

    @Test func boardMicButtonStartsAConversation() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.ui.startStop()
        #expect(await eventually { !rig.ui.listening })
        rig.board.emitControl(.micChanged(false))
        #expect(await eventually { !rig.ui.boardMicOn })
        rig.board.emitControl(.micChanged(true))
        #expect(await eventually { rig.ui.listening && rig.ui.boardMicOn })
        rig.ui.toggleBoardMic()
        #expect(await eventually { rig.board.micCalls == [false] })
        rig.controller.shutdown()
    }

    @Test func headsetLostShowsThePhoneMicChip() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.fake.emitAudioSession(AudioSessionMsg(kind: .routeChanged, route: .phoneMic))
        #expect(await eventually { rig.ui.micRoute == .phoneMic })
        #expect(rig.ui.chips.contains(.phoneMic))
        rig.controller.shutdown()
    }

    @Test func bundledPacksAndBoardGlyphsLoad() {
        let codes = BundledPacks.load().map(\.code)
        #expect(codes.contains("vi"))
        #expect(codes.contains("en"))
        #expect(!BoardGlyphSets.shared.ranges(for: .cjk).isEmpty)
    }
}
