import Foundation

// The multi-language conversation (P2.2): ARCHITECTURE §2 steps 1–8, the session machine of §3 and the failure
// behaviour of §6, driven against the `VoiceEngine` and `BoardLink` contracts. Replaces the EN↔VI pair logic of the
// old ConversationEngine; with the default pick (`en`) it does what that engine did.
//
//   Them → You:  board ADPCM → feedTheirAudio → `theirs` (generation) → confidence gate → TextPipeline(X→vi)
//                → engine translate → restore → speak (one ordered queue, ids)
//   You → Them:  `mine` → TurnAssembler → SubtitleTranslator(TextPipeline(vi→X) through the engine) → BoardText
//                → board subtitle

/// Owns the `SessionMachine` state and fills a `UIState` (fields and intents) for the views.
@MainActor
final class ConversationController {
    struct Tuning {
        /// Their results are dropped this long after the wearer's last words (the board mic hears the wearer too)
        var echoHold: TimeInterval = 1
        /// "Không nghe rõ" is spoken at most this often
        var unclearCooldown: TimeInterval = 4
        /// The idle check of `ConversationActivity`
        var tickInterval: TimeInterval = 5
        /// Board audio keeps the conversation alive; noted at most this often
        var boardAudioNoteInterval: TimeInterval = 1
        /// Lines kept on screen (both sides together)
        var maxLines = 100
        /// The board mic streams 16 kHz mono
        var boardSampleRate = 16_000
    }

    /// The pick when nothing is saved: the Swift app's EN ↔ VI pair.
    static let defaultPick = "en"
    static let pickKey = "conversation.pick"
    static let onlineAllowedKey = "conversation.onlineAllowed"
    /// Spoken (quietly, rate-limited) and shown for a phrase under the confidence gate, as in the Swift app.
    static let unclearCue = "Không nghe rõ"

    let ui: UIState
    private let engine: any VoiceEngine
    private let board: any BoardLink
    private let packs: [String: LanguagePack]
    private let home: LanguagePack?
    private let glossary: GlossaryStore?
    private let defaults: UserDefaults
    private let boardText: BoardText
    private let now: () -> Date
    private let tuning: Tuning

    /// The session state and their-side generation (`SessionMachine.advance`).
    private(set) var session = Session(state: .loading, generation: 0)
    /// Bumped on every state change: an async step started for an older state drops its result.
    private var epoch = 0
    private var started = false
    private var tasks: [Task<Void, Never>] = []

    // Languages
    private var caps: Capabilities?
    private var catalog: LanguageCatalog?
    private var onlineAllowed: Set<String>
    /// The last non-empty missing list: what the Download button fetches.
    private var pendingMissing: [MissingMsg] = []
    /// The language the pipelines and the board label are for.
    private var activeCode: String?
    private var pipeline: TextPipeline?
    private var glossaryTerms: [Term] = []

    // Engine and conversation on/off
    private var engineStarted = false
    private var openedOnce = false
    private var activity = ConversationActivity()
    private var micChain: Task<Void, Never>?

    // Their side
    private var decoder = ADPCMDecoder()
    private var theirQueue: [TheirsMsg] = []
    private var theirWorker: Task<Void, Never>?
    private var speechChain: Task<Void, Never>?
    private var nextSpeechId = 1
    private var nextTheirLine = 1
    private var lastUnclearCue = Date.distantPast
    private var lastBoardAudioNote = Date.distantPast

    // My side
    private var turns = TurnAssembler(turnGap: 2)
    private var subtitles: SubtitleTranslator?
    private var subtitleToken = 0
    private var myLastSpeech = Date.distantPast

    // Board
    private var boardChain: Task<Void, Never>?

    /// `packs` are every bundled pack, the home language (`LanguageCatalog.homeCode`) included. `glossary` nil: no
    /// glossary (the editor reports "Không lưu được").
    init(engine: any VoiceEngine, board: any BoardLink, packs: [LanguagePack], glossary: GlossaryStore?,
         defaults: UserDefaults = .standard, boardText: BoardText = BoardText(), ui: UIState,
         now: @escaping () -> Date = { Date() }, tuning: Tuning = Tuning()) {
        self.engine = engine
        self.board = board
        self.packs = Dictionary(packs.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        home = self.packs[LanguageCatalog.homeCode]
        self.glossary = glossary
        self.defaults = defaults
        self.boardText = boardText
        self.ui = ui
        self.now = now
        self.tuning = tuning
        onlineAllowed = Set(defaults.stringArray(forKey: Self.onlineAllowedKey) ?? [])
        bindIntents()
    }

    // MARK: Start / shutdown

    /// Subscribes to the engine, board and glossary streams, then runs §2 step 1 (capabilities → catalog → saved
    /// pick). Returns once the session has left `loading`; the rest runs on the streams. Idempotent.
    func start() async {
        guard !started else { return }
        started = true
        // Subscribe before any Task runs: subscribing inside a Task is a race (VoiceEngine, BoardLink)
        let ev = engine.events()
        let bev = board.events()
        let glossaryChanges = glossary?.changes()
        ui.session = session.state
        ui.board = board.currentState
        ui.languageNames = packs.mapValues(\.label)

        listen(ev.mine) { $0.handleMine($1) }
        listen(ev.theirs) { $0.handleTheirs($1) }
        listen(ev.gate) { $0.note($1 ? .gateOpen : .gateClosed) }
        listen(ev.ttsStart) { c, _ in c.note(.ttsStart) }
        listen(ev.ttsEnd) { c, _ in c.note(.ttsEnd) }
        listen(ev.audioSession) { $0.handleAudioSession($1) }
        listen(ev.download) { $0.handleDownload($1) }
        listen(bev.state) { $0.handleBoardState($1) }
        listen(bev.control) { $0.handleBoardControl($1) }
        tasks.append(Task { [weak self] in
            for await packet in bev.audio {
                guard let self else { return }
                await self.handleBoardAudio(packet)
            }
        })
        if let glossaryChanges { listen(glossaryChanges) { $0.glossaryChanged($1) } }
        let tick = tuning.tickInterval
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                self?.note(.tick)
            }
        })

        if let glossary {
            let terms = await glossary.terms
            if glossaryTerms.isEmpty { glossaryChanged(terms) }
        }
        await loadCatalog()
    }

    /// Ends every stream subscription and worker (tests; the app's controller lives as long as the app).
    func shutdown() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        theirWorker?.cancel()
        theirQueue.removeAll()
        epoch += 1
    }

    private func listen<Element: Sendable>(_ stream: AsyncStream<Element>,
                                           _ handle: @escaping (ConversationController, Element) -> Void) {
        tasks.append(Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                handle(self, element)
            }
        })
    }

    // MARK: Intents

    private func bindIntents() {
        ui.pickLanguage = { [weak self] in self?.pick($0) }
        ui.setOnlineAllowed = { [weak self] code, on in self?.setOnlineAllowed(code, on) }
        ui.download = { [weak self] in self?.apply(.downloadTapped) }
        ui.retry = { [weak self] in self?.apply(.retry) }
        ui.startStop = { [weak self] in
            guard let self else { return }
            note(ui.listening ? .userStop : .userStart)
        }
        ui.toggleBoardMic = { [weak self] in self?.toggleBoardMic() }
        ui.clear = { [weak self] in self?.clear() }
        ui.openTtsSettings = { [weak self] in
            guard let engine = self?.engine else { return }
            Task { try? await engine.openTtsSettings() }
        }
        ui.glossaryAdd = { [weak self] text in try self?.glossaryAdd(text) }
        ui.glossaryUpdate = { [weak self] id, text in try self?.glossaryUpdate(id, text) }
        ui.glossaryDelete = { [weak self] id in try self?.glossaryDelete(id) }
    }

    private func pick(_ code: String) {
        defaults.set(code, forKey: Self.pickKey)
        apply(.picked(code))
    }

    private func setOnlineAllowed(_ code: String, _ on: Bool) {
        if on { onlineAllowed.insert(code) } else { onlineAllowed.remove(code) }
        defaults.set(onlineAllowed.sorted(), forKey: Self.onlineAllowedKey)
        ui.onlineAllowed = onlineAllowed
        if let caps { applyCapabilities(caps) }
    }

    private func toggleBoardMic() {
        ui.boardMicOn.toggle()
        let on = ui.boardMicOn
        enqueueBoard { board in await board.setBoardMic(on) }
        if on { note(.userStart) }
    }

    private func clear() {
        ui.lines.removeAll()
        ui.myPartial = ""
        ui.theirPartial = ""
        turns.reset()
        subtitles?.reset()
        sendBoard("", .subtitle)
    }

    // MARK: Session machine

    private func apply(_ event: SessionEvent) {
        let old = session
        session = SessionMachine.advance(session, event)
        guard session.state != old.state else { return }
        epoch += 1
        ui.session = session.state
        Diag.log("session: \(old.state) → \(session.state) (gen \(session.generation))")
        enter(session.state)
    }

    private func enter(_ state: SessionState) {
        switch state {
        case .loading, .choosing, .failed:
            break
        case .checking(let code):
            show(code)
            check(code)
        case .needsDownload(_, let missing, _):
            if !missing.isEmpty { pendingMissing = missing }
            ui.downloadProgress = nil
        case .downloading:
            downloadMissing()
        case .preparing(let code, let restarts):
            prepare(code, restarts: restarts)
        case .running(let code, let restarts):
            running(code, restarts: restarts)
        case .switching(_, let to):
            // §2 step 7: the old pair's queued phrases and speech go; late results carry the old generation
            theirQueue.removeAll()
            let engine = self.engine
            Task { try? await engine.stopSpeaking() }
            show(to)
            check(to)
        }
    }

    /// §2 step 1: capabilities(home) → catalog → saved pick (default English).
    private func loadCatalog() async {
        let caps: Capabilities
        do {
            caps = try await engine.capabilities(home: LanguageCatalog.homeCode)
        } catch {
            Diag.log("controller: capabilities failed: \(error)")
            caps = Capabilities(recognizers: [:], translatable: [], vietnameseVoice: true)
        }
        applyCapabilities(caps)
        ui.ttsVoiceMissing = !caps.vietnameseVoice
        let saved = defaults.string(forKey: Self.pickKey) ?? Self.defaultPick
        apply(.catalogReady(saved: saved, offered: Set(ui.offeredPacks.map(\.code))))
    }

    private func applyCapabilities(_ caps: Capabilities) {
        self.caps = caps
        let catalog = LanguageCatalog(packs: Array(packs.values), caps: caps, platform: .ios,
                                      onlineConsent: onlineAllowed)
        self.catalog = catalog
        ui.offeredPacks = catalog.offered
        ui.onlineCodes = Set(catalog.offered.filter { catalog.chain($0.code).first == .osOnline }.map(\.code))
        // iOS has no online recognizer (LanguageCatalog), so there is nothing to opt in to
        ui.onlineCandidates = []
        ui.onlineAllowed = onlineAllowed
    }

    private func show(_ code: String) {
        ui.languageCode = code
        ui.languageLabel = packs[code]?.label ?? code
    }

    /// §2 step 2: what is missing for X ↔ vi. The Vietnamese voice is not a blocker (§6): its absence is the banner.
    private func check(_ code: String) {
        let e = epoch, engine = self.engine
        let pair = PairMsg(home: LanguageCatalog.homeCode, other: code, generation: session.generation)
        Task {
            var missing: [MissingMsg] = []
            do {
                missing = try await engine.missing(pair: pair)
                ui.ttsVoiceMissing = missing.contains { $0.kind == .ttsVoice }
            } catch {
                // Nothing known to be missing: the start reports what is really wrong
                Diag.log("controller: missing(\(code)) failed: \(error)")
            }
            guard epoch == e else { return }
            apply(.checked(missing.filter { $0.kind != .ttsVoice }))
        }
    }

    private func downloadMissing() {
        let items = pendingMissing, e = epoch, engine = self.engine
        ui.downloadProgress = nil
        Task {
            do {
                for item in items { try await engine.downloadItem(item) }
                guard epoch == e else { return }
                apply(.downloadDone)
            } catch {
                guard epoch == e else { return }
                apply(.downloadFailed(String(describing: error)))
            }
        }
    }

    private func handleDownload(_ msg: DownloadMsg) {
        guard case .downloading = session.state else { return }
        if !msg.done { ui.downloadProgress = msg.progress }
    }

    /// §2 step 4: pipelines for X, then `start`. A restart after a dead recognizer stops the engine first (the
    /// engine's `start` keeps a running pair of the same languages).
    private func prepare(_ code: String, restarts: Int) {
        guard let other = packs[code], home != nil else {
            apply(.startFailed("no language pack for \(code)"))
            return
        }
        do {
            try rebuildPipeline(other)
        } catch {
            apply(.startFailed("language pack \(code): \(error)"))
            return
        }
        if activeCode != code {
            activeCode = code
            makeSubtitles(code)
        }
        let chain = catalog?.chain(code) ?? []
        ui.online = chain.first == .osOnline
        let recognizer = (chain.first ?? .osOnDevice).rawValue
        let pair = PairMsg(home: LanguageCatalog.homeCode, other: code, generation: session.generation)
        let hints = hints(for: other), e = epoch, engine = self.engine
        Task {
            do {
                if restarts > 0 {
                    engineStarted = false
                    try? await engine.stop()
                }
                try await engine.start(pair: pair, recognizerX: recognizer, hints: hints)
                guard epoch == e else { return }
                engineStarted = true
                apply(.started)
            } catch {
                guard epoch == e else { return }
                apply(.startFailed(String(describing: error)))
            }
        }
    }

    private func running(_ code: String, restarts: Int) {
        sendLabel()
        if !openedOnce {
            // Opening the app starts a conversation (as the Swift app)
            openedOnce = true
            note(.userStart)
        } else if restarts > 0 && activity.isActive {
            setMic(true)
        }
    }

    // MARK: Pipelines and glossary

    private func rebuildPipeline(_ other: LanguagePack) throws {
        guard let home else { return }
        pipeline = try TextPipeline(home: home, other: other, glossary: glossaryTerms)
    }

    /// The other recognizer's hints (R12): the pack's, then every glossary term and variant.
    private func hints(for other: LanguagePack) -> [String] {
        var seen = Set<String>()
        return (other.hints + glossaryTerms.flatMap { [$0.text] + $0.variants }).filter { seen.insert($0).inserted }
    }

    /// §2 step 8: the glossary changed; pipelines rebuild and the recognizer gets the new hints.
    private func glossaryChanged(_ terms: [Term]) {
        glossaryTerms = terms
        ui.glossaryTerms = terms
        guard let code = activeCode, let other = packs[code] else { return }
        do {
            try rebuildPipeline(other)
        } catch {
            Diag.log("controller: pipeline rebuild failed: \(error)")
        }
        guard engineStarted else { return }
        let hints = hints(for: other), engine = self.engine
        Task { try? await engine.setHints(hints) }
    }

    private func glossaryAdd(_ text: String) throws {
        let store = try writableGlossary()
        try Self.precheck(text, terms: glossaryTerms, ignoring: nil)
        Task {
            do { try await store.add(text: text) } catch { Diag.log("glossary: add failed: \(error)") }
        }
    }

    private func glossaryUpdate(_ id: String, _ text: String) throws {
        let store = try writableGlossary()
        guard let term = glossaryTerms.first(where: { $0.id == id }) else { return }
        try Self.precheck(text, terms: glossaryTerms, ignoring: id)
        Task {
            do {
                try await store.update(id, text: text, variants: term.variants, fixed: term.fixed)
            } catch {
                Diag.log("glossary: update failed: \(error)")
            }
        }
    }

    private func glossaryDelete(_ id: String) throws {
        let store = try writableGlossary()
        Task {
            do { try await store.remove(id) } catch { Diag.log("glossary: delete failed: \(error)") }
        }
    }

    private struct GlossaryUnavailable: Error {}

    private func writableGlossary() throws -> GlossaryStore {
        guard let glossary, !glossary.isReadOnly else { throw GlossaryUnavailable() }
        return glossary
    }

    /// The store's checks a typed term can fail (GlossaryStore, same limits), made synchronously so the editor can
    /// show the message under the field; the store checks again when it saves.
    static func precheck(_ text: String, terms: [Term], ignoring id: String?) throws {
        let s = text.dartTrimmed
        if s.isEmpty { throw GlossaryValidationError(message: GlossaryMessages.empty) }
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069:
                throw GlossaryValidationError(message: GlossaryMessages.badCharacters)
            default: break
            }
        }
        if s.count > GlossaryStore.maxLength { throw GlossaryValidationError(message: GlossaryMessages.tooLong) }
        if id == nil && terms.count >= GlossaryStore.maxTerms {
            throw GlossaryValidationError(message: GlossaryMessages.tooMany)
        }
        let key = s.nfc.lowercased()
        let taken = terms.contains { t in t.id != id && ([t.text] + t.variants).contains { $0.nfc.lowercased() == key } }
        if taken { throw GlossaryValidationError(message: GlossaryMessages.duplicate) }
    }

    // MARK: Conversation on / off

    private func note(_ event: ConversationActivity.Event) {
        guard engineStarted else { return }
        switch activity.handle(event, at: now()) {
        case .start?:
            ui.listening = true
            setMic(true)
        case .stop?:
            ui.listening = false
            ui.myPartial = ""
            setMic(false)
        case nil:
            break
        }
    }

    /// Mic changes run one after another, in the order asked.
    private func setMic(_ on: Bool) {
        let previous = micChain, engine = self.engine
        micChain = Task { [weak self] in
            await previous?.value
            do {
                try await engine.micOn(on)
            } catch {
                guard on, let self else { return }
                Diag.log("conversation: mic not taken (\(error)), staying idle")
                activity.startFailed(at: now())
                ui.listening = false
            }
        }
    }

    private func handleAudioSession(_ msg: AudioSessionMsg) {
        if let route = msg.route { ui.micRoute = route }
        // The engine lost the mic (interruption, failed restart): the conversation ends until the next tap
        if msg.kind == .interrupted { note(.stop) }
    }

    // MARK: Them → You

    private func handleBoardAudio(_ packet: Data) async {
        let t = now()
        if t.timeIntervalSince(lastBoardAudioNote) >= tuning.boardAudioNoteInterval {
            lastBoardAudioNote = t
            note(.boardAudio)
        }
        let pcm = decoder.decode(packet)
        guard !pcm.isEmpty, engineStarted, case .running = session.state else { return }
        let e = epoch
        do {
            try await engine.feedTheirAudio(pcm, sampleRate: tuning.boardSampleRate)
        } catch {
            guard epoch == e, case .running = session.state else { return }
            Diag.log("controller: their recognizer failed: \(error)")
            apply(.recognizerDied)
        }
    }

    private var userIsSpeaking: Bool {
        !ui.myPartial.isEmpty || now().timeIntervalSince(myLastSpeech) < tuning.echoHold
    }

    private func handleTheirs(_ msg: TheirsMsg) {
        guard msg.generation == session.generation, let code = activeCode else { return }
        if userIsSpeaking {
            ui.theirPartial = ""
            return
        }
        guard msg.text.count > 1 else { return }
        if let min = packs[code]?.minConfidence, let confidence = msg.confidence, confidence < min {
            unclear(msg.text)
            return
        }
        theirQueue.append(msg)
        runTheirQueue()
    }

    /// Crowd noise, overlapping voices: speaking a wrong translation is worse than saying nothing, so the phrase is
    /// only shown dimmed and a short cue is spoken.
    private func unclear(_ text: String) {
        addTheirLine(source: text, target: Self.unclearCue, unclear: true)
        let t = now()
        if t.timeIntervalSince(lastUnclearCue) > tuning.unclearCooldown {
            lastUnclearCue = t
            say(Self.unclearCue)
        }
    }

    /// Translates and speaks phrases strictly in order: one worker, never a later phrase overtaking.
    private func runTheirQueue() {
        guard theirWorker == nil else { return }
        theirWorker = Task { [weak self] in
            while let self, !Task.isCancelled, !theirQueue.isEmpty {
                let msg = theirQueue.removeFirst()
                await translateTheirs(msg)
            }
            self?.theirWorker = nil
        }
    }

    private func translateTheirs(_ msg: TheirsMsg) async {
        guard msg.generation == session.generation, let pipeline, let code = activeCode else { return }
        let engine = self.engine, homeCode = LanguageCatalog.homeCode
        let translated: String
        do {
            translated = try await pipeline.translate(msg.text, .theirs) { @Sendable in
                try await engine.translate($0, from: code, to: homeCode)
            }
        } catch {
            // §6: their phrase is skipped and logged
            Diag.log("translate \(code)→\(homeCode) FAILED: \(error)")
            return
        }
        // Switched meanwhile: nothing of the old pair is shown or spoken (Review Focus 2)
        guard msg.generation == session.generation, !translated.isEmpty else { return }
        addTheirLine(source: msg.text, target: translated, unclear: false)
        say(translated)
    }

    /// Every utterance goes through one chain (ids in order); one queued before a switch is not spoken after it.
    private func say(_ text: String) {
        note(.ttsStart)
        let id = nextSpeechId
        nextSpeechId += 1
        let generation = session.generation, previous = speechChain, engine = self.engine
        speechChain = Task { [weak self] in
            await previous?.value
            guard let self, generation == session.generation else { return }
            do {
                try await engine.speak(text, id: id)
            } catch {
                Diag.log("speak \(id) failed: \(error)")
            }
        }
    }

    private func addTheirLine(source: String, target: String, unclear: Bool) {
        ui.lines.append(UILine(id: "t-\(nextTheirLine)", mine: false, source: source, target: target,
                               unclear: unclear, at: now()))
        nextTheirLine += 1
        trimLines()
    }

    private func trimLines() {
        if ui.lines.count > tuning.maxLines { ui.lines.removeFirst(ui.lines.count - tuning.maxLines) }
    }

    // MARK: You → Them

    private func makeSubtitles(_ code: String) {
        subtitles?.reset()
        subtitleToken += 1
        let token = subtitleToken
        subtitles = SubtitleTranslator(
            translate: { [weak self] text in await self?.translateMine(text, to: code) ?? text },
            onResult: { [weak self] turn, translated in
                guard let self, subtitleToken == token else { return }
                showSubtitle(translated, turn: turn)
            })
    }

    /// TextPipeline(vi→X) through the engine; on a translator failure the source text is kept (§6).
    private func translateMine(_ text: String, to code: String) async -> String {
        guard let pipeline else { return text }
        let engine = self.engine, homeCode = LanguageCatalog.homeCode
        do {
            return try await pipeline.translate(text, .mine) { @Sendable in
                try await engine.translate($0, from: homeCode, to: code)
            }
        } catch {
            Diag.log("translate \(homeCode)→\(code) FAILED (\(text.count) chars): \(error)")
            return text
        }
    }

    private func handleMine(_ msg: MineMsg) {
        let event: TranscriptEvent = msg.kind == .partial
            ? .partial(msg.text, audio: 0) : .final(msg.text, confidence: nil, audio: 0)
        let t = now()
        guard let change = turns.handle(event, at: t), let turn = turns.turn else { return }
        ui.myPartial = turn.partial
        if !turn.partial.isEmpty || change.final != nil { myLastSpeech = t }
        let id = "m-\(turn.id)"
        if let index = ui.lines.lastIndex(where: { $0.id == id }) {
            if ui.lines[index].source != turn.text {
                ui.lines[index].source = turn.text
                ui.lines[index].at = t
            }
        } else if !turn.text.isEmpty {
            ui.lines.append(UILine(id: id, mine: true, source: turn.text, target: "", at: t))
            trimLines()
        }
        if let final = change.final { subtitles?.addFinal(final, turn: turn.id) }
        subtitles?.setPartial(turn.partial, turn: turn.id)
    }

    private func showSubtitle(_ text: String, turn: Int) {
        if let index = ui.lines.lastIndex(where: { $0.id == "m-\(turn)" }) { ui.lines[index].target = text }
        // The board shows the current turn only; late results for an earlier turn just fix its line
        guard turns.turn?.id == turn else { return }
        sendBoard(boardText.encode(text, board.info.fontSets), .subtitle)
    }

    // MARK: Board

    private func handleBoardState(_ state: BoardState) {
        ui.board = state
        guard state == .ready else { return }
        // Review Focus 1: the clock and the label again on every ready
        sendBoard(BoardProtocol.timeText(at: now()), .time)
        sendLabel()
    }

    private func handleBoardControl(_ control: BoardControl) {
        switch control {
        case .micChanged(let on):
            // A tap on the board mic (off → on) starts a conversation
            if on && !ui.boardMicOn { note(.userStart) }
            ui.boardMicOn = on
        }
    }

    /// The running language's label, in its own script when the board has the font, else its Latin form.
    private func sendLabel() {
        guard let code = activeCode, let pack = packs[code] else { return }
        sendBoard(board.info.fontSets.covers(pack.script) ? pack.label : pack.labelLatin, .label)
    }

    private func sendBoard(_ text: String, _ kind: TextKind) {
        enqueueBoard { board in await board.sendText(text, kind: kind) }
    }

    /// Board writes run one after another, in the order asked.
    private func enqueueBoard(_ work: @escaping @Sendable (any BoardLink) async -> Void) {
        let previous = boardChain, board = self.board
        boardChain = Task {
            await previous?.value
            await work(board)
        }
    }
}

/// The language packs the app ships (`languages/*.json` in the bundle; read in place from the repository on the
/// Mac). A pack that does not parse is reported and left out.
enum BundledPacks {
    static func load(bundle: Bundle = .main) -> [LanguagePack] {
        var urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: SharedResources.Folder.languages.rawValue)
            ?? []
        if urls.isEmpty, let home = SharedResources.url(.languages, LanguageCatalog.homeCode, "json") {
            let directory = home.deletingLastPathComponent()
            urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            do {
                return try LanguagePack.parse(Data(contentsOf: url))
            } catch {
                SharedResources.reportMissing("language pack \(url.lastPathComponent)", error)
                return nil
            }
        }
    }
}
