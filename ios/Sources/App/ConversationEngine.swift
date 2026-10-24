import AVFAudio
import Foundation
import Observation
import os
import UIKit

/// Orchestrates two translation channels running in parallel:
///
///   Them → You:  ESP32 mic ─BLE─► EN recognition ─final phrase─► EN→VI ─► spoken into AirPods
///   You → Them:  AirPods mic ───► VI recognition ─partials─► VI→EN ─BLE─► subtitles on the ESP32
///
/// While you are speaking, "Them → You" results are dropped, because the ESP32 mic hears you too.
///
/// The AirPods mic is held only during a conversation (`ConversationActivity`): board speech, a translation to
/// speak or a tap starts one (your voice can't: the mic is off while idle, so tap before you speak); ten minutes
/// without speech ends it and gives the audio back to other apps (YouTube, TikTok…), which are only ducked
/// while it lasts.
@MainActor
@Observable
final class ConversationEngine {
    struct Line: Identifiable {
        let id = UUID()
        var source: String
        var target: String
        /// Recognized with low confidence: shown dimmed, not translated or spoken
        var unclear = false
        /// "You say" turn number (0 for "They say" lines)
        var turn = 0
        /// When the line was last spoken (final for theirs, last recognized words for yours): orders both sides
        /// into one conversation, so a turn you keep talking through moves below a line they said in between
        var at = Date()
    }

    enum Phase: Equatable {
        case idle
        case needsTranslationModels
        case preparing(String)
        case running
        case failed(String)
    }

    static let english = Locale.Language(identifier: "en")
    static let vietnamese = Locale.Language(identifier: "vi")

    private(set) var phase: Phase = .idle
    private(set) var board: ESPLink.State = .off
    private(set) var boardMicOn = true

    private(set) var theirLines: [Line] = []
    private(set) var theirPartial = ""
    private(set) var myLines: [Line] = []
    private(set) var myPartial = ""
    private(set) var mySubtitle = ""
    private(set) var voiceName = ""
    /// A conversation is going on: the AirPods mic is on ("You say" listens)
    private(set) var listening = false

    // MARK: Tuning

    /// A pause longer than this starts a new subtitle screen
    private var myTurns = TurnAssembler(turnGap: 2.0)
    /// Keep dropping ESP32 mic results this long after you stop (finalization lags slightly)
    private let echoHold: TimeInterval = 1.0
    /// English phrases below this mean word confidence are not spoken (measured: garbage 0.25–0.30, real ≥ 0.46)
    private let minConfidence = 0.4
    /// Don't repeat "không nghe rõ" more often than this
    private let unclearCooldown: TimeInterval = 4
    private var lastUnclearCue = Date.distantPast

    // MARK: Components

    let link = ESPLink()   // shared with the Claude relay (RelayModel)
    private var speaker: Speaker?
    private var englishIn: LiveTranscriber?
    private var vietnameseIn: LiveTranscriber?
    private var espSource: ESPAudioSource?
    private var mic: MicSource?
    private let gate = VoiceGate()
    private var activity = ConversationActivity()
    private let silence = SilencePlayer()
    private let boardAudioStamp = OSAllocatedUnfairLock<Date>(initialState: .distantPast)
    private var micFormat: AVAudioFormat?
    private var subtitleTranslator: SubtitleTranslator?
    private var theirFinals: AsyncStream<String>.Continuation?

    private var myLastSpeech = Date.distantPast

    init() {
        link.onStateChange = { [weak self] state in
            Task { @MainActor in self?.board = state }
        }
        link.onMicChange = { [weak self] on in
            Task { @MainActor in
                guard let self else { return }
                // A tap on the board mic (off → on) starts a conversation
                if on && !self.boardMicOn { self.note(.userStart) }
                self.boardMicOn = on
            }
        }
        // Midnight, a time zone or daylight-saving change, or a clock set: keep the board's lock-face clock right
        NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resendTimeIfConnected() }
        }
    }

    private func resendTimeIfConnected() {
        guard board == .ready else { return }
        NSTimeZone.resetSystemTimeZone()
        link.sendTime()
    }

    // MARK: Startup

    func start() async {
        guard phase == .idle || phase == .needsTranslationModels || isFailed else { return }

        let models = await (Translator.isInstalled(from: Self.english, to: Self.vietnamese),
                            Translator.isInstalled(from: Self.vietnamese, to: Self.english))
        guard models.0 && models.1 else {
            phase = .needsTranslationModels
            return
        }

        do {
            phase = .preparing("Requesting microphone access…")
            guard await AVAudioApplication.requestRecordPermission() else {
                phase = .failed("Microphone access denied. Enable it in Settings → Live Translator.")
                return
            }

            let english = LiveTranscriber(locale: Locale(identifier: "en-US"), engine: .speech)
            let vietnamese = LiveTranscriber(locale: Locale(identifier: "vi-VN"), engine: .dictation)
            phase = .preparing("Downloading English speech model…")
            try await english.installAssetsIfNeeded()
            phase = .preparing("Downloading Vietnamese speech model…")
            try await vietnamese.installAssetsIfNeeded()

            phase = .preparing("Loading models…")
            try await english.start { [weak self] event in
                Task { @MainActor in self?.handleTheirs(event) }
            }
            try await vietnamese.start { [weak self] event in
                Task { @MainActor in self?.handleMine(event) }
            }
            englishIn = english
            vietnameseIn = vietnamese

            startTheirPipeline(Translator(from: Self.english, to: Self.vietnamese))
            let viToEn = Translator(from: Self.vietnamese, to: Self.english)
            subtitleTranslator = SubtitleTranslator(translate: { try await viToEn.translate($0) }) { [weak self] turn, english in
                self?.showSubtitle(english, turn: turn)
            }

            guard let espFormat = english.audioFormat, let micFormat = vietnamese.audioFormat else {
                throw EngineError.noAudioFormat
            }
            let espSource = ESPAudioSource(target: espFormat) { english.feed($0) }
            let stamp = boardAudioStamp
            link.onAudioPacket = { [weak self] packet in
                espSource.handle(packet: packet)
                // Board speech keeps (or starts) the conversation; the main actor hears about it once a second
                let now = Date()
                let due = stamp.withLock { last in
                    guard now.timeIntervalSince(last) >= 1 else { return false }
                    last = now
                    return true
                }
                if due { Task { @MainActor in self?.note(.boardAudio) } }
            }
            self.espSource = espSource
            self.micFormat = micFormat

            observeAudioSession()
            startPhraseEndWatcher()
            startDiagnostics()
            startIdleTimer()
            phase = .running
            // Opening the app starts a conversation; the session is set up before the synthesizer touches it
            note(.userStart)

            let speaker = Speaker()
            speaker.onBusyChange = { [weak self] busy in self?.note(busy ? .ttsStart : .ttsEnd) }
            voiceName = speaker.voiceName
            self.speaker = speaker
            speaker.warmUp()
            Diag.log("engine: running")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func translationModelsReady() {
        phase = .idle
        Task { await start() }
    }

    func toggleBoardMic() {
        boardMicOn.toggle()
        link.setBoardMic(boardMicOn)
        if boardMicOn { note(.userStart) }
    }

    /// The "tap to start" control
    func startConversation() {
        note(.userStart)
    }

    /// The same control while listening: gives the AirPods mic back until the next tap
    func stopConversation() {
        note(.userStop)
    }

    func clearHistory() {
        theirLines.removeAll()
        myLines.removeAll()
        myTurns.reset()
        myPartial = ""
        subtitleTranslator?.reset()
        mySubtitle = ""
        link.send(text: "", kind: .subtitle)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat: echo cancellation, routes through the AirPods mic; speech still plays in the earbuds.
        // mixWithOthers + duckOthers: a video playing in another app gets quieter instead of stopping.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetoothHFP, .mixWithOthers, .duckOthers])
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
    }

    // MARK: Conversation on / off

    private func note(_ event: ConversationActivity.Event) {
        guard phase == .running else { return }
        switch activity.handle(event, at: Date()) {
        case .start?: beginConversation(after: event)
        case .stop?: endConversation(after: event)
        case nil: break
        }
    }

    /// Takes the AirPods mic: session in voice chat (other audio ducked), mic engine on.
    /// The idle silence keeps playing until the mic runs: if taking the mic fails (common when starting it from
    /// the background) the app must still be playing audio, or iOS suspends it and the board link goes quiet.
    private func beginConversation(after event: ConversationActivity.Event) {
        Diag.log("conversation: start (\(event))")
        listening = true
        do {
            try configureAudioSession()
            try startMic()
            silence.stop()
        } catch {
            Diag.log("conversation: mic start failed (\(error.localizedDescription)), staying idle")
            fallBackToIdle()
        }
    }

    /// The mic could not be taken: back to idle in the mixable playback session. Silence keeps the app alive
    /// in the background (the board link's keepalive) and translations of board speech still play through it.
    private func fallBackToIdle() {
        listening = false
        activity.startFailed(at: Date())
        mic?.stop()
        mic = nil
        myPartial = ""
        startSilence()
    }

    /// Gives the mic and the session back: other apps return to full volume and the AirPods to A2DP.
    /// Silence keeps playing (mixable, no mic) so the app stays alive in the background for the board.
    private func endConversation(after event: ConversationActivity.Event) {
        Diag.log("conversation: end (\(event))")
        listening = false
        mic?.stop()
        mic = nil
        myPartial = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Diag.log("conversation: session deactivate failed: \(error.localizedDescription)")
        }
        startSilence()
    }

    private func startMic() throws {
        guard let vietnamese = vietnameseIn, let micFormat else { throw EngineError.noAudioFormat }
        mic?.stop()
        let fresh = MicSource(target: micFormat, gate: gate, sink: { vietnamese.feed($0) },
                              onSpeechStart: { [weak self] in Task { @MainActor in self?.note(.gateOpen) } },
                              onSpeechEnd: { [weak self] in
                                  vietnamese.finalizeNow()
                                  Task { @MainActor in self?.note(.gateClosed) }
                              })
        try fresh.start()
        mic = fresh
    }

    private func startSilence() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try silence.start()
        } catch {
            Diag.log("idle: silence start failed: \(error.localizedDescription)")
        }
    }

    private var idleTimerTask: Task<Void, Never>?

    private func startIdleTimer() {
        idleTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.note(.tick)
            }
        }
    }

    /// Every translation is spoken through here: it starts a conversation if idle; if the mic can't be taken the
    /// session stays in idle playback (mixable), which plays speech too
    private func say(_ text: String, quiet: Bool = false) {
        note(.ttsStart)
        speaker?.speak(text, quiet: quiet)
    }

    // MARK: Them → You

    private var userIsSpeaking: Bool {
        !myPartial.isEmpty || Date().timeIntervalSince(myLastSpeech) < echoHold
    }

    private func handleTheirs(_ event: TranscriptEvent) {
        Diag.log("EN \(Self.describe(event)) gate=\(userIsSpeaking) myPartial=\(myPartial.count)ch sinceMine=\(String(format: "%.1f", Date().timeIntervalSince(myLastSpeech)))s")
        if userIsSpeaking {
            theirPartial = ""
            return
        }
        switch event {
        case .partial(let text):
            theirPartial = text
        case .final(let text, let confidence):
            theirPartial = ""
            guard text.count > 1 else { return }
            if let confidence, confidence < minConfidence {
                handleUnclear(text, confidence: confidence)
            } else {
                theirFinals?.yield(text)
            }
        }
    }

    /// A phrase the recognizer is unsure about (crowd noise, overlapping voices). Speaking a wrong
    /// translation is worse than saying nothing, so it is only shown dimmed and a short cue is spoken.
    private func handleUnclear(_ text: String, confidence: Double) {
        Diag.log(String(format: "EN unclear (%.2f): \"%@\"", confidence, text))
        theirLines.append(Line(source: text, target: "Không nghe rõ", unclear: true))
        Self.trim(&theirLines)
        let now = Date()
        if now.timeIntervalSince(lastUnclearCue) > unclearCooldown {
            lastUnclearCue = now
            say("Không nghe rõ", quiet: true)
        }
    }

    /// Translate and speak phrases strictly in order, never letting a later one overtake
    private func startTheirPipeline(_ translator: Translator) {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        theirFinals = continuation
        Task { [weak self] in
            for await english in stream {
                let t0 = Date()
                let vietnamese: String
                do {
                    vietnamese = try await translator.translate(english)
                } catch {
                    Diag.log("translate EN→VI FAILED: \(error)")
                    continue
                }
                Diag.log(String(format: "translate EN→VI %.0f ms", Date().timeIntervalSince(t0) * 1000))
                guard let self else { return }
                self.theirLines.append(Line(source: english, target: vietnamese))
                Self.trim(&self.theirLines)
                self.say(vietnamese)
            }
        }
    }

    // MARK: You → Them

    private func handleMine(_ event: TranscriptEvent) {
        Diag.log("VI \(Self.describe(event, full: true))")
        let now = Date()
        guard let change = myTurns.handle(event, at: now), let turn = myTurns.turn else { return }
        myPartial = turn.partial
        if !turn.partial.isEmpty || change.final != nil { myLastSpeech = now }

        if myLines.last?.turn != turn.id {
            myLines.append(Line(source: "", target: "", turn: turn.id))
            Self.trim(&myLines)
        }
        if let index = myLines.lastIndex(where: { $0.turn == turn.id }), myLines[index].source != turn.text {
            myLines[index].source = turn.text
            myLines[index].at = now
        }
        // The panel shows the recognized text (loanwords fixed); the translator gets it with vocatives
        // dropped and service phrases spelled out (VietnameseFixup)
        if let final = change.final {
            Diag.log("VI turn \(turn.id): \"\(turn.text)\"")
            subtitleTranslator?.addFinal(VietnameseFixup.forTranslation(final), turn: turn.id)
        }
        subtitleTranslator?.setPartial(VietnameseFixup.forTranslation(turn.partial), turn: turn.id)
    }

    private func showSubtitle(_ english: String, turn: Int) {
        guard let index = myLines.lastIndex(where: { $0.turn == turn }) else { return }
        Diag.log("EN turn \(turn): \"\(english)\"")
        myLines[index].target = english
        // The board shows the current turn only; late results for an earlier turn just fix its line
        guard index == myLines.count - 1 else { return }
        mySubtitle = english
        link.send(text: english, kind: .subtitle)
    }

    // MARK: Phrase end

    private var phraseEndTask: Task<Void, Never>?

    /// The board stops streaming in silence; once packets pause, finalize the English phrase right away
    /// so it is translated and spoken without waiting for the next utterance.
    private func startPhraseEndWatcher() {
        phraseEndTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let espSource = self.espSource else { continue }
                if espSource.streamEnded(after: 0.25) {
                    Diag.log("EN stream paused → finalize")
                    self.englishIn?.finalizeNow()
                }
            }
        }
    }

    // MARK: Audio session recovery

    /// A phone call or Siri interrupts the session and stops the mic engine. When it ends the mic comes back only
    /// if a conversation is going on and iOS says to resume; otherwise the conversation ends, so the app never
    /// grabs the mic back while you watch a video. While idle only the mixable silence is restarted (it keeps the
    /// app alive for the board without touching other audio). A media services reset rebuilds whichever runs.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in self?.interruptionEnded(shouldResume: shouldResume) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            Task { @MainActor [weak self] in self?.mediaServicesReset() }
        }
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard phase == .running else { return }
        if !activity.isActive {
            Diag.log("idle: interruption ended → silence back on")
            startSilence()
        } else if shouldResume {
            restartMic(reason: "interruption ended")
        } else {
            Diag.log("conversation: interruption ended without resume")
            note(.stop)
        }
    }

    private func mediaServicesReset() {
        guard phase == .running else { return }
        if activity.isActive {
            restartMic(reason: "media services reset")
        } else {
            startSilence()
        }
    }

    private func restartMic(reason: String) {
        do {
            try configureAudioSession()
            try startMic()
            Diag.log("mic: restarted (\(reason))")
        } catch {
            Diag.log("conversation: mic start failed (restart after \(reason): \(error.localizedDescription)), staying idle")
            fallBackToIdle()
        }
    }

    // MARK: Diagnostics

    private var diagnosticsTask: Task<Void, Never>?

    private func startDiagnostics() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            Diag.log("session: INTERRUPTION \(note.userInfo ?? [:])")
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            let route = AVAudioSession.sharedInstance().currentRoute
            Diag.log("session: route change \(note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "?") in=\(route.inputs.map(\.portName)) out=\(route.outputs.map(\.portName))")
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            Diag.log("session: MEDIA SERVICES RESET")
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
            Diag.log("engine: AVAudioEngine CONFIGURATION CHANGE")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            Diag.log("app: background")
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            Diag.log("app: foreground")
        }
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let c = Diag.drain()
                Diag.log("stats/5s board=\(self.board) pkts=\(c["esp.packets"] ?? 0) micBufs=\(c["mic.buffers"] ?? 0) feedEN=\(c["feed.en-US"] ?? 0) feedVI=\(c["feed.vi-VN"] ?? 0) rmsEN=\((c["rms.en-US"] ?? 0) / max(1, c["bufs.en-US"] ?? 1))‰ rmsVI=\((c["rms.vi-VN"] ?? 0) / max(1, c["bufs.vi-VN"] ?? 1))‰ fedEN=\(Int(self.englishIn?.fed ?? 0))s fedVI=\(Int(self.vietnameseIn?.fed ?? 0))s gate=\(self.userIsSpeaking) myPartial=\"\(self.myPartial.prefix(30))\" ttsQueue=\(self.speaker?.queued ?? -1) listening=\(self.listening)")
            }
        }
    }

    /// The panels keep the last 50 lines, so hours of conversation do not grow memory without bound
    private static func trim(_ lines: inout [Line]) {
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
    }

    private static func describe(_ event: TranscriptEvent, full: Bool = false) -> String {
        switch event {
        case .partial(let t): "partial(\(t.count)) \"\(full ? Substring(t) : t.suffix(40))\""
        case .final(let t, let c): "FINAL(\(t.count)) conf=\(c.map { String(format: "%.2f", $0) } ?? "-") \"\(full ? Substring(t) : t.suffix(40))\""
        }
    }

    enum EngineError: LocalizedError {
        case noAudioFormat
        var errorDescription: String? { "Could not get an audio format for the speech model." }
    }
}
