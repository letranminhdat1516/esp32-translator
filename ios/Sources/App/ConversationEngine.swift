import AVFAudio
import Foundation
import Observation
import UIKit

/// Orchestrates two translation channels running in parallel:
///
///   Them → You:  ESP32 mic ─BLE─► EN recognition ─final phrase─► EN→VI ─► spoken into AirPods
///   You → Them:  AirPods mic ───► VI recognition ─partials─► VI→EN ─BLE─► subtitles on the ESP32
///
/// While you are speaking, "Them → You" results are dropped, because the ESP32 mic hears you too.
@MainActor
@Observable
final class ConversationEngine {
    struct Line: Identifiable {
        let id = UUID()
        var source: String
        var target: String
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

    // MARK: Tuning

    /// A pause longer than this starts a new subtitle screen
    private let turnGap: TimeInterval = 2.0
    /// Keep dropping ESP32 mic results this long after you stop (finalization lags slightly)
    private let echoHold: TimeInterval = 1.0

    // MARK: Components

    private let link = ESPLink()
    private var speaker: Speaker?
    private var englishIn: LiveTranscriber?
    private var vietnameseIn: LiveTranscriber?
    private var espSource: ESPAudioSource?
    private var mic: MicSource?
    private var subtitleTranslator: LatestWinsTranslator?
    private var theirFinals: AsyncStream<String>.Continuation?

    private var myLastSpeech = Date.distantPast
    private var myTurnCommitted = ""

    init() {
        link.onStateChange = { [weak self] state in
            Task { @MainActor in self?.board = state }
        }
        link.onMicChange = { [weak self] on in
            Task { @MainActor in self?.boardMicOn = on }
        }
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
            try configureAudioSession()

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
            subtitleTranslator = LatestWinsTranslator(
                translator: Translator(from: Self.vietnamese, to: Self.english)
            ) { [weak self] english in
                self?.showSubtitle(english)
            }

            let speaker = Speaker()
            speaker.warmUp()
            voiceName = speaker.voiceName
            self.speaker = speaker

            guard let espFormat = english.audioFormat, let micFormat = vietnamese.audioFormat else {
                throw EngineError.noAudioFormat
            }
            let espSource = ESPAudioSource(target: espFormat) { english.feed($0) }
            link.onAudioPacket = { espSource.handle(packet: $0) }
            self.espSource = espSource

            let mic = MicSource(target: micFormat, sink: { vietnamese.feed($0) },
                                onSpeechEnd: { vietnamese.finalizeNow() })
            try mic.start()
            self.mic = mic

            startPhraseEndWatcher()
            startDiagnostics()
            phase = .running
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
    }

    func clearHistory() {
        theirLines.removeAll()
        myLines.removeAll()
        mySubtitle = ""
        link.send(text: "", kind: .subtitle)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat: echo cancellation, routes through the AirPods mic; speech still plays in the earbuds
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetoothHFP, .duckOthers])
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
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
        case .final(let text):
            theirPartial = ""
            if text.count > 1 { theirFinals?.yield(text) }
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
                self.speaker?.speak(vietnamese)
            }
        }
    }

    // MARK: You → Them

    private func handleMine(_ event: TranscriptEvent) {
        Diag.log("VI \(Self.describe(event))")
        let now = Date()
        let text: String
        switch event {
        case .partial(let t): text = t
        case .final(let t): text = t
        }
        guard !text.isEmpty else {
            myPartial = ""
            return
        }

        if now.timeIntervalSince(myLastSpeech) > turnGap {
            myTurnCommitted = ""
            myLines.append(Line(source: "", target: ""))
        }
        myLastSpeech = now

        switch event {
        case .partial(let t):
            myPartial = t
        case .final(let t):
            myPartial = ""
            myTurnCommitted = myTurnCommitted.isEmpty ? t : myTurnCommitted + " " + t
        }

        let turnText = [myTurnCommitted, myPartial].filter { !$0.isEmpty }.joined(separator: " ")
        if !myLines.isEmpty { myLines[myLines.count - 1].source = turnText }
        subtitleTranslator?.submit(turnText)
    }

    private func showSubtitle(_ english: String) {
        mySubtitle = english
        if !myLines.isEmpty { myLines[myLines.count - 1].target = english }
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
                Diag.log("stats/5s board=\(self.board) pkts=\(c["esp.packets"] ?? 0) micBufs=\(c["mic.buffers"] ?? 0) feedEN=\(c["feed.en-US"] ?? 0) feedVI=\(c["feed.vi-VN"] ?? 0) rmsEN=\((c["rms.en-US"] ?? 0) / max(1, c["bufs.en-US"] ?? 1))‰ rmsVI=\((c["rms.vi-VN"] ?? 0) / max(1, c["bufs.vi-VN"] ?? 1))‰ fedEN=\(Int(self.englishIn?.fed ?? 0))s fedVI=\(Int(self.vietnameseIn?.fed ?? 0))s gate=\(self.userIsSpeaking) myPartial=\"\(self.myPartial.prefix(30))\" ttsQueue=\(self.speaker?.queued ?? -1)")
            }
        }
    }

    private static func describe(_ event: TranscriptEvent) -> String {
        switch event {
        case .partial(let t): "partial(\(t.count)) \"\(t.suffix(40))\""
        case .final(let t): "FINAL(\(t.count)) \"\(t.suffix(40))\""
        }
    }

    enum EngineError: LocalizedError {
        case noAudioFormat
        var errorDescription: String? { "Could not get an audio format for the speech model." }
    }
}
