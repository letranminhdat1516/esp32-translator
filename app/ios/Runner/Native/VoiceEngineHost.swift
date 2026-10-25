import AVFAudio
import Flutter
import Foundation
import UIKit

/// `VoiceEngineApi` on iOS. Pigeon calls the sync methods on the main thread; they and the async ones run on
/// the main actor in `VoiceEngine`. Thrown errors carry `EngineError` codes.
final class VoiceEngineHost: VoiceEngineApi {
    private let engine: VoiceEngine

    init(events: EventQueue) {
        engine = MainActor.assumeIsolated { VoiceEngine(events: events) }
    }

    func capabilities() throws -> CapabilitiesMsg { try MainActor.assumeIsolated { try engine.capabilities() } }
    func missing(pair: PairMsg) throws -> [MissingMsg] { try MainActor.assumeIsolated { try engine.missing(pair) } }
    func download(item: MissingMsg) async throws { try await engine.download(item) }
    func start(pair: PairMsg, recognizerX: String, hints: [String]) async throws {
        try await engine.start(pair, recognizer: recognizerX, hints: hints)
    }
    func stop() throws { MainActor.assumeIsolated { engine.stop() } }
    func micOn(on: Bool) throws { try MainActor.assumeIsolated { try engine.micOn(on) } }
    func feedTheirAudio(pcm16le: FlutterStandardTypedData, sampleRate: Int64) throws {
        MainActor.assumeIsolated { engine.feedTheirAudio(pcm16le.data, sampleRate: Double(sampleRate)) }
    }
    func translate(text: String, from: String, to: String) async throws -> String {
        try await engine.translate(text, from: from, to: to)
    }
    func speak(text: String, id: Int64) throws { try MainActor.assumeIsolated { try engine.speak(text, id: id) } }
    func stopSpeaking() throws { MainActor.assumeIsolated { engine.stopSpeaking() } }
    func setHints(hints: [String]) throws { MainActor.assumeIsolated { engine.setHints(hints) } }
    func openTtsSettings() throws { MainActor.assumeIsolated { engine.openTtsSettings() } }
}

/// The native half of the translator: two recognizers (the board's language X fed from Dart, the home language
/// from the gated mic), offline translation, speech output and the audio session. Turns, the conversation
/// on/off logic and subtitles live in Dart; this only reports events.
@MainActor
final class VoiceEngine {
    private let events: EventQueue
    private let session = AudioSession()
    private let gate = VoiceGate()

    private var pair: PairMsg?
    private var theirs: LiveTranscriber?
    private var mine: LiveTranscriber?
    private var theirConverter: BufferConverter?
    private var mic: MicSource?
    private var speaker: Speaker?
    /// Dart asked for the mic (micOn(true)) and has not released it
    private var micWanted = false
    private var translators: [String: Translator] = [:]
    /// Finalizes the board phrase once Dart stops feeding audio (the board streams only while it hears speech)
    private var theirPause: DispatchWorkItem?
    private static let theirPauseGap: TimeInterval = 0.25
    /// The pair's generation, read by the board recognizer's result task
    private let generation = Generation()

    private let capabilityCache = CapabilitiesCache()
    private var downloads: Downloads!
    private static let queryTimeout: TimeInterval = 5

    init(events: EventQueue, downloadWork: Downloads.Work = .live) {
        self.events = events
        session.onChange = { [weak self] change in self?.sessionChanged(change) }
        downloads = Downloads(events: events, home: { [weak self] in self?.homeLanguage ?? defaultHomeLanguage },
                              work: downloadWork, onDone: { [weak self] in self?.refreshCapabilities() })
        capabilityCache.refresh(home: defaultHomeLanguage)
    }

    /// After a download the cached capabilities are stale; Dart calls capabilities() again (ARCHITECTURE §5)
    private func refreshCapabilities() {
        capabilityCache.invalidate()
        capabilityCache.refresh(home: homeLanguage)
    }

    // MARK: Capabilities and downloads

    /// Fast: the background-gathered value, else gathered now (bounded wait)
    func capabilities() throws -> CapabilitiesMsg {
        guard let caps = capabilityCache.get(home: homeLanguage, timeout: Self.queryTimeout) else {
            throw EngineErrors.notReady("capabilities timed out")
        }
        return caps
    }

    func missing(_ pair: PairMsg) throws -> [MissingMsg] {
        guard let missing = Blocking.run(timeout: Self.queryTimeout, { await MissingAssembly.gather(pair) }) else {
            throw EngineErrors.notReady("missing timed out")
        }
        return missing
    }

    func download(_ item: MissingMsg) async throws {
        try await downloads.download(item)
    }

    private var homeLanguage: String { pair?.home ?? defaultHomeLanguage }

    // MARK: Start / stop

    /// Builds both recognizers for the pair. Idempotent: the same languages keep running (the generation and
    /// hints are updated); other languages replace the running pair.
    func start(_ pair: PairMsg, recognizer: String, hints: [String]) async throws {
        guard recognizer == RecognizerKinds.onDevice else {
            throw EngineErrors.notReady("recognizer \(recognizer) is not available on iOS")
        }
        if let running = self.pair, running.home == pair.home, running.other == pair.other, theirs != nil {
            self.pair = pair
            generation.value = pair.generation
            await theirs?.setHints(hints)
            return
        }
        tearDown()
        // Asked here so the prompt comes before the first conversation; micOn checks the answer
        _ = await AVAudioApplication.requestRecordPermission()

        guard let x = await LiveTranscriber.resolve(pair.other) else {
            throw EngineErrors.notReady("no on-device recognizer for \(pair.other)")
        }
        guard let home = await LiveTranscriber.resolve(pair.home) else {
            throw EngineErrors.notReady("no on-device recognizer for \(pair.home)")
        }
        for t in [x, home] {
            if await t.assetStatus != .installed {
                throw EngineErrors.notReady("speech model for \(t.locale.identifier) is not installed")
            }
        }
        generation.value = pair.generation
        let events = self.events
        let generation = self.generation
        do {
            try await x.start { event in
                if let msg = EngineMapping.theirs(event, generation: generation.value) { events.send(.theirs(msg)) }
            }
            try await home.start { event in
                events.send(.mine(EngineMapping.mine(event, now: Date())))
            }
        } catch {
            await x.stop()
            await home.stop()
            throw EngineErrors.notReady("recognizers did not start: \(error.localizedDescription)")
        }
        guard let xFormat = x.audioFormat, home.audioFormat != nil else {
            await x.stop()
            await home.stop()
            throw EngineErrors.notReady("no audio format for the speech models")
        }
        await x.setHints(hints)
        self.pair = pair
        theirs = x
        mine = home
        theirConverter = BufferConverter(target: xFormat)
        let speaker = Speaker(language: pair.home)
        speaker.onStart = { [events] id in events.send(.ttsStart(id)) }
        speaker.onEnd = { [events] id in events.send(.ttsEnd(id)) }
        speaker.warmUp()
        self.speaker = speaker
        if micWanted {
            try? micOn(true)
        } else {
            session.startSilence()
        }
        Diag.log("engine: running \(x.locale.identifier) (\(x.engine)) / \(home.locale.identifier) (\(home.engine)), voice \(speaker.voiceName)")
    }

    /// Releases the mic, both recognizers, speech output and the audio session. Idempotent.
    func stop() {
        micWanted = false
        tearDown()
    }

    /// Stops everything but remembers whether Dart wants the mic (a pair change takes it again)
    private func tearDown() {
        theirPause?.cancel()
        theirPause = nil
        releaseMic()
        speaker?.stop()
        speaker = nil
        let running = [theirs, mine].compactMap { $0 }
        theirs = nil
        mine = nil
        theirConverter = nil
        if !running.isEmpty || pair != nil {
            Task { for t in running { await t.stop() } }
            session.release()
        }
        pair = nil
    }

    // MARK: Mic

    /// Takes the mic (voice-chat session, other audio ducked) or gives it back (mixable silence, so the app stays
    /// alive for the board). If taking it fails the engine stays idle, keeps the silence and throws `notReady`.
    func micOn(_ on: Bool) throws {
        guard on else {
            micWanted = false
            guard mic != nil else { return }
            releaseMic()
            session.deactivate()
            if pair != nil { session.startSilence() }
            return
        }
        guard mine != nil else { throw EngineErrors.notReady("start the engine before the mic") }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw EngineErrors.notReady("microphone access denied")
        }
        micWanted = true
        guard mic == nil else { return }
        do {
            try takeMic()
        } catch {
            Diag.log("conversation: mic start failed (\(error.localizedDescription)), staying idle")
            micWanted = false
            releaseMic()
            session.startSilence()
            throw EngineErrors.notReady("mic did not start: \(error.localizedDescription)")
        }
    }

    /// The idle silence keeps playing until the mic runs: if taking the mic fails (common when starting it from
    /// the background) the app must still be playing audio, or iOS suspends it and the board link goes quiet.
    private func takeMic() throws {
        guard let home = mine, let format = home.audioFormat else { throw EngineErrors.notReady("not started") }
        try session.configureForConversation()
        mic?.stop()
        let events = self.events
        let fresh = MicSource(target: format, gate: gate, sink: { home.feed($0) },
                              onSpeechStart: { events.send(.gate(true)) },
                              onSpeechEnd: {
                                  home.finalizeNow()
                                  events.send(.gate(false))
                              })
        try fresh.start()
        mic = fresh
        session.stopSilence()
    }

    private func releaseMic() {
        mic?.stop()
        mic = nil
    }

    // MARK: Board audio

    /// PCM from the board (Dart decodes the BLE ADPCM). Audio before `start` finishes is dropped.
    func feedTheirAudio(_ bytes: Data, sampleRate: Double) {
        guard let x = theirs, let converter = theirConverter,
              let buffer = EngineMapping.pcm16Buffer(bytes, sampleRate: sampleRate),
              let converted = converter.convert(buffer) else { return }
        Diag.count("esp.packets")
        x.feed(converted)
        // The board stops streaming in silence; once packets pause, finalize the phrase right away so it is
        // translated and spoken without waiting for the next utterance
        theirPause?.cancel()
        let pause = DispatchWorkItem { [weak x] in x?.finalizeNow() }
        theirPause = pause
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.theirPauseGap, execute: pause)
    }

    func setHints(_ hints: [String]) {
        guard let x = theirs else { return }
        Task { await x.setHints(hints) }
    }

    // MARK: Translation

    /// Offline translation with the installed Apple models. Any failure is `translateFailed`; Dart decides the
    /// fallback.
    func translate(_ text: String, from: String, to: String) async throws -> String {
        let key = "\(from)>\(to)"
        let translator = translators[key] ?? Translator(from: Locale.Language(identifier: from),
                                                        to: Locale.Language(identifier: to))
        translators[key] = translator
        do {
            return try await translator.translate(text)
        } catch {
            // A session made before the models were installed stays broken: make a fresh one next time
            translators[key] = nil
            throw EngineErrors.translateFailed("\(key): \(error.localizedDescription)")
        }
    }

    // MARK: Speech output

    func speak(_ text: String, id: Int64) throws {
        guard let speaker else { throw EngineErrors.notReady("start the engine before speaking") }
        speaker.speak(text, id: id)
    }

    func stopSpeaking() {
        speaker?.stop()
    }

    /// iOS has no link to the voice settings; this opens the app's page in Settings
    func openTtsSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Audio session

    /// A phone call or Siri interrupts the session and stops the mic engine. When it ends the mic comes back only
    /// if Dart still wants it and iOS says to resume (then `resumed`); otherwise the mic is released and no
    /// `resumed` follows, so the app never grabs the mic back while you watch a video. While idle only the
    /// mixable silence is restarted. A media services reset rebuilds whichever runs.
    private func sessionChanged(_ change: AudioSession.Change) {
        switch change {
        case .interruptionBegan:
            events.send(.audioSession(AudioSessionMsg(kind: .interrupted)))
        case .interruptionEnded(let shouldResume):
            guard pair != nil else { return }
            if !micWanted {
                session.startSilence()
                events.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
            } else if shouldResume, restartMic(reason: "interruption ended") {
                events.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
            } else {
                Diag.log("conversation: interruption ended without resume, mic released")
                try? micOn(false)
            }
        case .routeChanged(let route):
            events.send(.audioSession(AudioSessionMsg(kind: .routeChanged, route: route)))
        case .mediaServicesReset:
            guard pair != nil else { return }
            if !micWanted {
                session.startSilence()
            } else if !restartMic(reason: "media services reset") {
                return
            }
            events.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
        }
    }

    /// True when the mic runs again; on failure the engine is idle (silence on, mic released)
    private func restartMic(reason: String) -> Bool {
        do {
            try takeMic()
            Diag.log("mic: restarted (\(reason))")
            return true
        } catch {
            Diag.log("conversation: mic restart after \(reason) failed: \(error.localizedDescription)")
            micWanted = false
            releaseMic()
            session.startSilence()
            events.send(.audioSession(AudioSessionMsg(kind: .interrupted)))
            return false
        }
    }
}

/// The current pair generation, written on the main actor and read from the recognizer's result task
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64 = 0

    var value: Int64 {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
