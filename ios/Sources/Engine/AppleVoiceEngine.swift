import AVFAudio
import Foundation
import os

// The iOS `VoiceEngine` (ARCHITECTURE "Revision 2026-10-29" R3), reshaped from the Flutter app's
// app/ios/Runner/Native/VoiceEngineHost.swift: the same engine, called in-process (async functions) with its
// events on the Core `Broadcast` streams instead of a pigeon channel.

/// Audio session changes the engine reacts to
enum AudioSessionChange {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(AudioRoute)
    case mediaServicesReset
}

/// The audio session as the engine drives it (`AudioSession` on iOS)
@MainActor
protocol EngineAudioSession: AnyObject {
    /// Called on the main actor
    var onChange: ((AudioSessionChange) -> Void)? { get set }
    var currentRoute: AudioRoute { get }
    /// Voice chat, other audio ducked (mic held)
    func configureForConversation() throws
    func stopSilence()
    func deactivate()
    /// Mixable silence that keeps the app running in the background
    func startSilence()
    /// Engine stopped: no silence, session released
    func release()
}

/// Speech output (`Speaker` on iOS)
@MainActor
protocol EngineSpeaker: AnyObject {
    var onStart: ((Int) -> Void)? { get set }
    var onEnd: ((Int) -> Void)? { get set }
    var voiceName: String { get }
    func speak(_ text: String, id: Int)
    func stop()
    func warmUp()
}

/// The gated mic (`MicSource` on iOS)
protocol EngineMic: AnyObject {
    func start() throws
    func stop()
}

/// What the engine needs from the device, replaceable in tests (`AppleVoiceEngine.live()` on iOS)
struct AppleEnginePlatform {
    typealias MakeMic = @MainActor (_ format: AVAudioFormat, _ gate: VoiceGate,
                                    _ sink: @escaping (AVAudioPCMBuffer) -> Void,
                                    _ onSpeechStart: @escaping () -> Void,
                                    _ onSpeechEnd: @escaping () -> Void) -> EngineMic
    typealias Translate = @Sendable (String) async throws -> String

    var session: EngineAudioSession
    var makeSpeaker: @MainActor (_ language: String) -> EngineSpeaker
    var makeMic: MakeMic
    var micPermitted: @MainActor () -> Bool
    /// Asked at the start of a fresh start so the prompt comes before the first conversation
    var requestMicPermission: @MainActor () async -> Void
    var recognizer: RecognizerPair.Factory
    /// A translator for one direction (language codes)
    var makeTranslator: @MainActor (_ from: String, _ to: String) -> Translate
    var downloads: Downloads.Work
    var openSettings: @MainActor () -> Void
    /// Framework queries; must not need the main actor
    var gatherCapabilities: @Sendable (_ home: String) async -> CapabilitiesMsg
    var gatherMissing: @Sendable (PairMsg) async -> [MissingMsg]
}

/// The native half of the translator: two recognizers (the board's language X fed with board PCM, the home
/// language from the gated mic), offline translation, speech output and the audio session. Turns, the
/// conversation on/off logic and subtitles live in the controller; this only reports events.
@MainActor
final class AppleVoiceEngine: VoiceEngine {
    private nonisolated let sink = EngineEventSink()
    private let platform: AppleEnginePlatform
    private var session: EngineAudioSession { platform.session }
    private let voiceGate = VoiceGate()

    /// Both recognizers; serializes start/stop across their awaits
    private let recognizers: RecognizerPair
    private var pair: PairMsg? { recognizers.pair }
    private var theirRecognizer: (any Recognizer)? { recognizers.theirs }
    private var homeRecognizer: (any Recognizer)? { recognizers.mine }
    private var theirConverter: BufferConverter?
    private var mic: EngineMic?
    private var speaker: EngineSpeaker?
    /// The controller asked for the mic (micOn(true)) and has not released it
    private var micWanted = false
    private var translators: [String: AppleEnginePlatform.Translate] = [:]
    /// Finalizes the board phrase once board audio stops coming (the board streams only while it hears speech)
    private var theirPause: DispatchWorkItem?
    private static let theirPauseGap: TimeInterval = 0.25
    private nonisolated let capabilityCache: CapabilitiesCache
    /// The home language capabilities were last asked for (re-gathered after a download)
    private nonisolated let capabilitiesHome = OSAllocatedUnfairLock<String?>(initialState: nil)
    private nonisolated let gatherMissing: @Sendable (PairMsg) async -> [MissingMsg]
    private var downloads: Downloads!

    init(platform: AppleEnginePlatform) {
        self.platform = platform
        capabilityCache = CapabilitiesCache(gather: platform.gatherCapabilities)
        gatherMissing = platform.gatherMissing
        recognizers = RecognizerPair(events: sink, factory: platform.recognizer,
                                     beforeStart: platform.requestMicPermission)
        session.onChange = { [weak self] change in self?.sessionChanged(change) }
        downloads = Downloads(events: sink, work: platform.downloads,
                              onDone: { [weak self] in self?.refreshCapabilities() })
    }

    // MARK: Events

    nonisolated var mine: AsyncStream<MineMsg> { sink.mine.stream() }
    nonisolated var theirs: AsyncStream<TheirsMsg> { sink.theirs.stream() }
    nonisolated var gate: AsyncStream<Bool> { sink.gate.stream() }
    nonisolated var ttsStart: AsyncStream<Int> { sink.ttsStart.stream() }
    nonisolated var ttsEnd: AsyncStream<Int> { sink.ttsEnd.stream() }
    nonisolated var audioSession: AsyncStream<AudioSessionMsg> { sink.audioSession.stream() }
    nonisolated var download: AsyncStream<DownloadMsg> { sink.download.stream() }

    // MARK: Capabilities and downloads

    /// The cached value for `home`, else gathered now. Runs off the main actor (the gather is detached).
    nonisolated func capabilities(home: String) async throws -> Capabilities {
        capabilitiesHome.withLock { $0 = home }
        return try await capabilityCache.get(home: home).toModel()
    }

    /// The framework queries run off the main actor
    nonisolated func missing(pair: PairMsg) async throws -> [MissingMsg] {
        await gatherMissing(pair)
    }

    func downloadItem(_ item: MissingMsg) async throws {
        try await downloads.download(item)
    }

    /// After a download the cached capabilities are stale; the caller asks capabilities(home) again (ARCHITECTURE §5)
    private func refreshCapabilities() {
        capabilityCache.invalidate()
        if let home = capabilitiesHome.withLock({ $0 }) { capabilityCache.refresh(home: home) }
    }

    // MARK: Start / stop

    /// Builds both recognizers for the pair. Idempotent: the same languages keep running (the generation and
    /// hints are updated); other languages replace the running pair. A `stop` or a later `start` that comes in
    /// while this one awaits wins: this one then throws `notReady` and leaves nothing running.
    func start(pair: PairMsg, recognizerX: String, hints: [String]) async throws {
        guard recognizerX == RecognizerKinds.onDevice else {
            throw EngineErrors.notReady("recognizer \(recognizerX) is not available on iOS")
        }
        let sameLanguages = self.pair.map { $0.home == pair.home && $0.other == pair.other } ?? false
        if !sameLanguages { tearDown() }
        guard try await recognizers.start(pair, hints: hints) else { return }
        // A fresh pair is running. No await from here on, so no stop or start can interleave.
        guard let x = theirRecognizer, let xFormat = x.audioFormat else { return }
        theirConverter = BufferConverter(target: xFormat)
        let speaker = platform.makeSpeaker(pair.home)
        let sink = self.sink
        speaker.onStart = { id in sink.send(.ttsStart(id)) }
        speaker.onEnd = { id in sink.send(.ttsEnd(id)) }
        self.speaker = speaker
        // The session is set up before the synthesizer touches it (as in the Swift app)
        if micWanted {
            do {
                try micOnNow(true)
            } catch {
                // micOn fell back to idle (silence on); the controller must learn the mic is gone
                Diag.log("engine: mic not taken back after start: \(error)")
                sink.send(.audioSession(AudioSessionMsg(kind: .interrupted)))
            }
        } else {
            session.startSilence()
        }
        speaker.warmUp()
        Diag.log("engine: running \(x.locale.identifier) / \(homeRecognizer?.locale.identifier ?? "-"), voice \(speaker.voiceName)")
    }

    /// Releases the mic, both recognizers, speech output and the audio session; a start in progress gives up.
    /// Idempotent.
    func stop() async throws {
        micWanted = false
        tearDown()
        recognizers.stop()
    }

    /// Stops what this engine built on top of the recognizers (mic, speech output, session) but remembers
    /// whether the controller wants the mic (a pair change takes it again). The recognizers themselves are
    /// replaced by `RecognizerPair.start` or stopped by `stop`.
    private func tearDown() {
        theirPause?.cancel()
        theirPause = nil
        releaseMic()
        speaker?.stop()
        speaker = nil
        theirConverter = nil
        if recognizers.isRunning { session.release() }
    }

    // MARK: Mic

    /// Takes the mic (voice-chat session, other audio ducked) or gives it back (mixable silence, so the app stays
    /// alive for the board). If taking it fails the engine stays idle, keeps the silence and throws `notReady`.
    func micOn(_ on: Bool) async throws {
        try micOnNow(on)
    }

    private func micOnNow(_ on: Bool) throws {
        guard on else {
            micWanted = false
            guard mic != nil else { return }
            releaseMic()
            session.deactivate()
            if pair != nil { session.startSilence() }
            return
        }
        guard homeRecognizer != nil else { throw EngineErrors.notReady("start the engine before the mic") }
        guard platform.micPermitted() else { throw EngineErrors.notReady("microphone access denied") }
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
        guard let home = homeRecognizer, let format = home.audioFormat else {
            throw EngineErrors.notReady("not started")
        }
        try session.configureForConversation()
        mic?.stop()
        let sink = self.sink
        let fresh = platform.makeMic(format, voiceGate, { home.feed($0) },
                                     { sink.send(.gate(true)) },
                                     {
                                         home.finalizeNow()
                                         sink.send(.gate(false))
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

    /// PCM from the board (the controller decodes the BLE ADPCM). Audio before `start` finishes is dropped.
    func feedTheirAudio(_ pcm: [Int16], sampleRate: Int) async throws {
        guard let x = theirRecognizer, let converter = theirConverter,
              let buffer = EngineMapping.pcm16Buffer(pcm, sampleRate: Double(sampleRate)),
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

    func setHints(_ hints: [String]) async throws {
        guard let x = theirRecognizer else { return }
        await x.setHints(hints)
    }

    // MARK: Translation

    /// Offline translation with the installed Apple models. Any failure is `translateFailed`; the caller decides
    /// the fallback.
    func translate(_ text: String, from: String, to: String) async throws -> String {
        let key = "\(from)>\(to)"
        let translator = translators[key] ?? platform.makeTranslator(from, to)
        translators[key] = translator
        do {
            return try await translator(text)
        } catch {
            // A session made before the models were installed stays broken: make a fresh one next time
            translators[key] = nil
            throw EngineErrors.translateFailed("\(key): \(error.localizedDescription)")
        }
    }

    // MARK: Speech output

    func speak(_ text: String, id: Int) async throws {
        guard let speaker else { throw EngineErrors.notReady("start the engine before speaking") }
        speaker.speak(text, id: id)
    }

    func stopSpeaking() async throws {
        speaker?.stop()
    }

    /// iOS has no link to the voice settings; this opens the app's page in Settings
    func openTtsSettings() async throws {
        platform.openSettings()
    }

    // MARK: Audio session

    /// A phone call or Siri interrupts the session and stops the mic engine. When it ends the mic comes back only
    /// if the controller still wants it and iOS says to resume (then `resumed`); otherwise the mic is released and
    /// no `resumed` follows, so the app never grabs the mic back while you watch a video. While idle only the
    /// mixable silence is restarted. A media services reset rebuilds whichever runs.
    private func sessionChanged(_ change: AudioSessionChange) {
        switch change {
        case .interruptionBegan:
            sink.send(.audioSession(AudioSessionMsg(kind: .interrupted)))
        case .interruptionEnded(let shouldResume):
            guard pair != nil else { return }
            if !micWanted {
                session.startSilence()
                sink.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
            } else if shouldResume, restartMic(reason: "interruption ended") {
                sink.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
            } else {
                Diag.log("conversation: interruption ended without resume, mic released")
                try? micOnNow(false)
            }
        case .routeChanged(let route):
            sink.send(.audioSession(AudioSessionMsg(kind: .routeChanged, route: route)))
        case .mediaServicesReset:
            guard pair != nil else { return }
            if !micWanted {
                session.startSilence()
            } else if !restartMic(reason: "media services reset") {
                return
            }
            sink.send(.audioSession(AudioSessionMsg(kind: .resumed, route: session.currentRoute)))
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
            sink.send(.audioSession(AudioSessionMsg(kind: .interrupted)))
            return false
        }
    }
}
