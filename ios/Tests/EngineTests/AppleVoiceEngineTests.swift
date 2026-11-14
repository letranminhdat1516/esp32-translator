import AVFAudio
import XCTest
@testable import TranslatorCore

/// AppleVoiceEngine on fakes (no mic, speech model, audio session or speech output): the guards before `start`,
/// start/stop re-entrancy, the warm-up order, a mic failure surfaced as an event, translation, speech events,
/// capabilities with the passed home, downloads, board audio and the audio-session reactions.
@MainActor
final class AppleVoiceEngineTests: XCTestCase {
    private let enVi = PairMsg(home: "vi", other: "en", generation: 1)
    private let onDevice = RecognizerKind.osOnDevice.rawValue

    private func rig(en: [FakeRecognizer] = [FakeRecognizer("en")], vi: [FakeRecognizer] = [FakeRecognizer("vi")],
                     ja: [FakeRecognizer] = []) -> EngineRig {
        EngineRig(["en": en, "vi": vi, "ja": ja])
    }

    // MARK: Guards

    func testWhisperIsNotOfferedOnIOS() async {
        let r = rig()
        let error = await engineError { try await r.engine.start(pair: self.enVi, recognizerX: "whisper", hints: []) }
        XCTAssertEqual(error, .notReady)
    }

    func testMicAndSpeechNeedAStartedEngine() async {
        let r = rig()
        let mic = await engineError { try await r.engine.micOn(true) }
        XCTAssertEqual(mic, .notReady)
        let speak = await engineError { try await r.engine.speak("xin chào", id: 1) }
        XCTAssertEqual(speak, .notReady)
    }

    func testIdleCallsAreHarmless() async throws {
        let e = rig().engine
        try await e.setHints(["Đà Nẵng"])
        try await e.stopSpeaking()
        try await e.micOn(false)
        try await e.stop()
        try await e.stop()
    }

    // MARK: Start / stop

    /// The session is set up (idle silence) before the synthesizer is warmed up, as in the Swift app
    func testStartSetsUpTheSessionThenWarmsUpTheVoice() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: ["Bến Thành"])
        XCTAssertEqual(r.log.calls, ["session.startSilence", "speaker.warmUp"])
        XCTAssertEqual(r.speakers.map(\.language), ["vi"], "the voice speaks the home language")
    }

    func testStartWithTheSameLanguagesKeepsTheRunningPair() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.start(pair: PairMsg(home: "vi", other: "en", generation: 4), recognizerX: onDevice,
                                 hints: ["Q.1"])
        XCTAssertEqual(r.speakers.count, 1, "nothing is rebuilt")
        XCTAssertEqual(r.log.calls, ["session.startSilence", "speaker.warmUp"])
    }

    func testStopDuringStartLeavesNothingRunning() async throws {
        let x = FakeRecognizer("en", holdStart: true), home = FakeRecognizer("vi")
        let r = rig(en: [x], vi: [home])
        let engine = r.engine
        let start = Task { try await engine.start(pair: self.enVi, recognizerX: self.onDevice, hints: []) }
        await until { x.isHeld }
        XCTAssertTrue(x.isHeld)
        try await engine.stop()
        x.release()
        let error = await engineError { try await start.value }
        XCTAssertEqual(error, .notReady)
        await settle()
        XCTAssertTrue(r.speakers.isEmpty, "a start overtaken by stop builds no speech output")
        XCTAssertFalse(r.log.calls.contains("session.startSilence"), "nor touches the session")
        XCTAssertTrue(x.stopped)
        let speak = await engineError { try await engine.speak("x", id: 1) }
        XCTAssertEqual(speak, .notReady)
    }

    func testASecondStartSupersedesAFirstOneInProgress() async throws {
        let x1 = FakeRecognizer("en", holdStart: true)
        let r = rig(en: [x1], vi: [FakeRecognizer("vi"), FakeRecognizer("vi")], ja: [FakeRecognizer("ja")])
        let engine = r.engine
        let first = Task { try await engine.start(pair: self.enVi, recognizerX: self.onDevice, hints: []) }
        await until { x1.isHeld }
        try await engine.start(pair: PairMsg(home: "vi", other: "ja", generation: 2), recognizerX: onDevice, hints: [])
        x1.release()
        let error = await engineError { try await first.value }
        XCTAssertEqual(error, .notReady)
        await settle()
        XCTAssertEqual(r.speakers.count, 1, "only the winning start builds speech output")
        XCTAssertTrue(x1.stopped)
    }

    func testStopReleasesTheSessionAndTheVoice() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.stop()
        XCTAssertEqual(r.log.calls, ["session.startSilence", "speaker.warmUp", "speaker.stop", "session.release"])
    }

    // MARK: Mic

    func testMicOnTakesTheMicAndReportsTheGate() async throws {
        let home = FakeRecognizer("vi")
        let r = rig(vi: [home])
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        XCTAssertEqual(Array(r.log.calls.suffix(3)), ["session.configure", "mic.make", "session.stopSilence"])
        let mic = try XCTUnwrap(r.mics.last)
        XCTAssertTrue(mic.started)
        mic.onSpeechStart()
        mic.onFinalize()
        XCTAssertEqual(home.finalized, 1, "the gate's early finalize point finalizes the phrase")
        mic.onSpeechEnd()
        await until { recorder.all.count >= 2 }
        XCTAssertEqual(home.finalized, 1, "the gate closing does not finalize again")
        XCTAssertEqual(recorder.all.filter { if case .gate = $0 { return true } else { return false } },
                       [.gate(true), .gate(false)])
        try await r.engine.micOn(false)
        XCTAssertTrue(mic.stopped)
        XCTAssertEqual(Array(r.log.calls.suffix(2)), ["session.deactivate", "session.startSilence"])
    }

    func testMicDeniedIsNotReady() async throws {
        let r = rig()
        r.micPermitted = false
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        let error = await engineError { try await r.engine.micOn(true) }
        XCTAssertEqual(error, .notReady)
        XCTAssertTrue(r.mics.isEmpty)
    }

    /// Taking the mic fails: the engine stays idle with the silence on (the app keeps running) and says so
    func testMicFailureLeavesTheEngineIdleAndThrows() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        r.micFails = true
        let error = await engineError { try await r.engine.micOn(true) }
        XCTAssertEqual(error, .notReady)
        XCTAssertEqual(r.log.calls.last, "session.startSilence")
    }

    /// The mic is wanted across a language switch; if it cannot be taken back the caller must hear of it
    func testMicNotTakenBackAfterASwitchIsSurfacedAsAnInterruption() async throws {
        let r = rig(vi: [FakeRecognizer("vi"), FakeRecognizer("vi")], ja: [FakeRecognizer("ja")])
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.micFails = true
        try await r.engine.start(pair: PairMsg(home: "vi", other: "ja", generation: 2), recognizerX: onDevice,
                                 hints: [])
        await until { recorder.all.contains(.audioSession(AudioSessionMsg(kind: .interrupted))) }
        XCTAssertTrue(recorder.all.contains(.audioSession(AudioSessionMsg(kind: .interrupted))))
        XCTAssertEqual(Array(r.log.calls.suffix(2)), ["session.startSilence", "speaker.warmUp"],
                       "idle silence on, then the voice warmed up")
    }

    func testMicWantedIsTakenAgainAfterASwitch() async throws {
        let r = rig(vi: [FakeRecognizer("vi"), FakeRecognizer("vi")], ja: [FakeRecognizer("ja")])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        try await r.engine.start(pair: PairMsg(home: "vi", other: "ja", generation: 2), recognizerX: onDevice,
                                 hints: [])
        XCTAssertEqual(r.mics.count, 2)
        XCTAssertTrue(r.mics[0].stopped)
        XCTAssertTrue(r.mics[1].started)
        XCTAssertEqual(Array(r.log.calls.suffix(4)),
                       ["session.configure", "mic.make", "session.stopSilence", "speaker.warmUp"])
    }

    // MARK: Audio session

    // Ruling: `.interrupted` only when the mic is really lost; the interruption's begin emits nothing; an end with
    // resume retakes a wanted mic and then emits `.resumed` (as the Swift app's ConversationEngine did)

    func testInterruptionBeginEmitsNothing() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.interruptionBegan)
        await settle()
        XCTAssertEqual(recorder.all, [])
        XCTAssertEqual(r.mics.count, 1)
        XCTAssertFalse(r.mics[0].stopped, "the mic is left to the system until the interruption ends")
    }

    func testInterruptionEndedWithResumeRetakesAWantedMicThenEmitsResumed() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.interruptionBegan)
        r.session.onChange?(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(r.mics.count, 2, "the mic is rebuilt before the event")
        XCTAssertTrue(r.mics[1].started)
        await until { !recorder.all.isEmpty }
        await settle()
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .resumed, route: .headset))])
    }

    func testInterruptionEndedWithResumeButAFailingMicEmitsInterrupted() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.micFails = true
        r.session.onChange?(.interruptionBegan)
        r.session.onChange?(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(r.log.calls.last, "session.startSilence", "idle silence keeps the app alive")
        await until { !recorder.all.isEmpty }
        await settle()
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .interrupted))])
    }

    func testInterruptionEndedWithoutResumeReleasesTheMicAndEmitsInterrupted() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.interruptionBegan)
        r.session.onChange?(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(r.mics[0].stopped)
        XCTAssertEqual(r.mics.count, 1, "the mic is not grabbed back")
        XCTAssertEqual(Array(r.log.calls.suffix(2)), ["session.deactivate", "session.startSilence"])
        await until { !recorder.all.isEmpty }
        await settle()
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .interrupted))])
        let micAgain = await engineError { try await r.engine.micOn(true) }
        XCTAssertNil(micAgain, "the controller may take the mic again later")
    }

    func testRouteChangesAreReported() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        r.session.onChange?(.routeChanged(.phoneMic))
        await until { !recorder.all.isEmpty }
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .routeChanged, route: .phoneMic))])
    }

    /// A media services reset kills the audio engines: a wanted mic is rebuilt (then `resumed`), an idle engine
    /// only gets its silence back; with no pair nothing happens
    func testMediaServicesResetRebuildsAWantedMic() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        r.session.onChange?(.mediaServicesReset)
        XCTAssertEqual(r.log.calls, [], "nothing runs before start")
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.mediaServicesReset)
        XCTAssertEqual(r.mics.count, 2, "the mic is rebuilt")
        XCTAssertTrue(r.mics[1].started)
        await until { !recorder.all.isEmpty }
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .resumed, route: .headset))])
    }

    func testMediaServicesResetWhileIdleRestartsTheSilence() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        r.session.onChange?(.mediaServicesReset)
        XCTAssertEqual(r.log.calls.last, "session.startSilence")
        XCTAssertTrue(r.mics.isEmpty)
    }

    /// The mic cannot be rebuilt after a reset: the engine is idle (silence on) and reports an interruption
    func testMediaServicesResetWithAFailingMicReportsAnInterruption() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.micFails = true
        r.session.onChange?(.mediaServicesReset)
        XCTAssertEqual(r.log.calls.last, "session.startSilence")
        await until { !recorder.all.isEmpty }
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .interrupted))])
    }

    // MARK: Speech output and translation

    func testSpeakForwardsStartAndEndByID() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.speak("xin chào", id: 7)
        let speaker = try XCTUnwrap(r.speakers.first)
        XCTAssertEqual(speaker.spoken.map(\.1), [7])
        speaker.onStart?(7)
        speaker.onEnd?(7)
        await until { recorder.all.count >= 2 }
        // ttsStart and ttsEnd are separate streams: their relative arrival order is not part of the contract
        XCTAssertEqual(Set(recorder.all.map { "\($0)" }), ["ttsStart(7)", "ttsEnd(7)"])
        XCTAssertEqual(recorder.all.count, 2)
        try await r.engine.stopSpeaking()
        XCTAssertEqual(r.log.calls.last, "speaker.stop")
    }

    func testTranslateUsesOneTranslatorPerDirection() async throws {
        let r = rig()
        let a = try await r.engine.translate("hello", from: "en", to: "vi")
        let b = try await r.engine.translate("bye", from: "en", to: "vi")
        let c = try await r.engine.translate("chào", from: "vi", to: "en")
        XCTAssertEqual([a, b, c], ["hello[vi]", "bye[vi]", "chào[en]"])
        XCTAssertEqual(r.translatorsMade, ["en>vi", "vi>en"])
    }

    /// A session made before the models were installed stays broken: a failure is `translateFailed` and the next
    /// call gets a fresh translator
    func testTranslateFailureIsTypedAndRebuildsTheTranslator() async throws {
        let r = rig()
        r.translate = { _, _, _ in throw FakeFailure() }
        let error = await engineError { _ = try await r.engine.translate("hello", from: "en", to: "vi") }
        XCTAssertEqual(error, .translateFailed)
        r.translate = { text, _, _ in text }
        let ok = try await r.engine.translate("hello", from: "en", to: "vi")
        XCTAssertEqual(ok, "hello")
        XCTAssertEqual(r.translatorsMade, ["en>vi", "en>vi"])
    }

    func testOpenTtsSettings() async throws {
        let r = rig()
        try await r.engine.openTtsSettings()
        XCTAssertEqual(r.settingsOpened, 1)
    }

    // MARK: Capabilities, missing, downloads

    func testCapabilitiesUseThePassedHomeAndMapToTheModel() async throws {
        let r = rig()
        let caps = try await r.engine.capabilities(home: "vi")
        XCTAssertEqual(caps, Capabilities(recognizers: ["en": [.osOnDevice]], translatable: ["en", "vi"],
                                          vietnameseVoice: true))
        _ = try await r.engine.capabilities(home: "vi")
        XCTAssertEqual(r.capabilityHomes.get, ["vi"], "the second call is served from the cache")
    }

    /// The framework queries must not need the main actor: they run while the main actor waits on them
    nonisolated func testCapabilitiesAndMissingRunOffTheMainActor() async throws {
        let engine = await MainActor.run { rig().engine }
        _ = try await engine.capabilities(home: "vi")
        let missing = try await engine.missing(pair: PairMsg(home: "vi", other: "en", generation: 1))
        XCTAssertEqual(missing, [MissingMsg(kind: .ttsVoice, language: "vi")])
    }

    func testADownloadReGathersTheCapabilitiesOfTheLastHome() async throws {
        let r = rig()
        _ = try await r.engine.capabilities(home: "vi")
        try await r.engine.downloadItem(MissingMsg(kind: .translation, language: "en", from: "en", to: "vi"))
        await until { r.capabilityHomes.get.count >= 2 }
        XCTAssertEqual(r.capabilityHomes.get, ["vi", "vi"])
    }

    func testDownloadFailureIsTypedAndReported() async throws {
        let r = rig()
        r.downloadWork.speech = { _, _ in throw DownloadFailure("no network") }
        let recorder = EventRecorder(r.engine.events())
        let item = MissingMsg(kind: .speechModel, language: "en")
        let error = await engineError { try await r.engine.downloadItem(item) }
        XCTAssertEqual(error, .downloadFailed)
        await until { recorder.all.count >= 2 }
        XCTAssertEqual(recorder.all.last, .download(DownloadMsg(item: item, progress: 0, done: true, error: "no network")))
    }

    // MARK: Board audio

    /// A pause in board audio is filled with digital silence so SpeechTranscriber ends the phrase itself:
    /// finalize corrupts its following utterances (ios/Tools/latency-harness, PAD=silence)
    func testBoardAudioIsFedToTheirRecognizerAndPaddedWithSilenceOnAPauseNeverFinalized() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let r = rig(en: [x], vi: [home])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio([Int16](repeating: 100, count: 320), sampleRate: 16_000)
        XCTAssertEqual(x.fedFrames, 320)
        await until { x.fedFrames >= 320 + 16_000 / 5 }
        XCTAssertGreaterThanOrEqual(x.fedFrames, 320 + 16_000 / 5, "silence follows the last packet")
        XCTAssertEqual(x.finalized, 0, "their recognizer is never finalized on a pause")
        XCTAssertEqual(home.fedFrames, 0, "only their recognizer is padded")
    }

    func testPaddingStopsWithTheEngine() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        await until { x.fedFrames > 320 }
        try await r.engine.stop()
        let fed = x.fedFrames
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(x.fedFrames, fed)
        XCTAssertEqual(x.finalized, 0)
    }

    /// Padding does not count as board audio: a dead recognizer is still reported by the next real packet, and
    /// padding stops feeding it
    func testPaddingDoesNotMaskADeadRecognizer() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        await until { x.fedFrames > 320 }
        x.failFatally()
        try? await Task.sleep(for: .milliseconds(60))
        let fed = x.fedFrames
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(x.fedFrames, fed, "a dead recognizer is not padded")
        let error = await engineError { try await r.engine.feedTheirAudio(self.pcm, sampleRate: 16_000) }
        XCTAssertEqual(error, .notReady)
    }

    /// Phone-only's death signal: the same check without audio, for either recognizer
    func testCheckRecognizersReportsADeadRecognizer() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        let before = await engineError { try await r.engine.checkRecognizers() }
        XCTAssertEqual(before, .notReady, "before start")
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.checkRecognizers()
        x.failFatally()
        var after: EngineError?
        for _ in 0..<200 where after == nil {
            after = await engineError { try await r.engine.checkRecognizers() }
            if after == nil { try? await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(after, .notReady)
        XCTAssertEqual(x.fedFrames, 0, "checking feeds nothing")
    }

    // MARK: Board audio while their recognizer is not running (the controller's "recognizer died" signal)

    private let pcm = [Int16](repeating: 100, count: 320)

    func testBoardAudioBeforeStartIsNotReady() async {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        let error = await engineError { try await r.engine.feedTheirAudio(self.pcm, sampleRate: 16_000) }
        XCTAssertEqual(error, .notReady)
        XCTAssertEqual(x.fedFrames, 0)
    }

    func testBoardAudioAfterStopIsNotReady() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.stop()
        let error = await engineError { try await r.engine.feedTheirAudio(self.pcm, sampleRate: 16_000) }
        XCTAssertEqual(error, .notReady)
    }

    /// Their recognizer's analysis ended with an error (it will not resume): every feed throws `notReady` until
    /// a start succeeds again, and that start (same pair) builds a fresh recognizer
    func testBoardAudioAfterAFatalRecognizerErrorIsNotReadyUntilARestart() async throws {
        let dead = FakeRecognizer("en"), fresh = FakeRecognizer("en")
        let r = rig(en: [dead, fresh], vi: [FakeRecognizer("vi"), FakeRecognizer("vi")])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        dead.failFatally()
        for _ in 0..<2 {
            let error = await engineError { try await r.engine.feedTheirAudio(self.pcm, sampleRate: 16_000) }
            XCTAssertEqual(error, .notReady)
        }
        let fedBeforeFailure = dead.fedFrames
        try await r.engine.start(pair: PairMsg(home: "vi", other: "en", generation: 2), recognizerX: onDevice,
                                 hints: [])
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        XCTAssertGreaterThan(fresh.fedFrames, 0, "the restart runs a fresh recognizer")
        XCTAssertEqual(dead.fedFrames, fedBeforeFailure)
        XCTAssertTrue(dead.stopped)
    }

    /// The home recognizer's analysis ended with an error: board audio throws `notReady` too (the controller's
    /// one "recognizer died" signal, so the user's side is restarted once, then `failed`), the mic cannot be taken
    /// for a dead recognizer, and a start with the same pair rebuilds everything (P2, ARCHITECTURE §6)
    func testADeadHomeRecognizerIsNotReadyUntilARestart() async throws {
        let dead = FakeRecognizer("vi"), fresh = FakeRecognizer("vi")
        let r = rig(en: [FakeRecognizer("en"), FakeRecognizer("en")], vi: [dead, fresh])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        dead.failFatally()
        let feed = await engineError { try await r.engine.feedTheirAudio(self.pcm, sampleRate: 16_000) }
        XCTAssertEqual(feed, .notReady, "a dead home recognizer is reported, not fed around")
        let mic = await engineError { try await r.engine.micOn(true) }
        XCTAssertEqual(mic, .notReady, "the mic is not taken for a dead recognizer")
        XCTAssertTrue(r.mics.isEmpty)

        try await r.engine.start(pair: PairMsg(home: "vi", other: "en", generation: 2), recognizerX: onDevice,
                                 hints: [])
        XCTAssertEqual(r.speakers.count, 2, "a dead home recognizer counts as a different pair: all is rebuilt")
        try await r.engine.feedTheirAudio(pcm, sampleRate: 16_000)
        try await r.engine.micOn(true)
        let sink = try XCTUnwrap(r.mics.last).sink
        sink(try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: XCTUnwrap(fresh.audioFormat), frameCapacity: 160)).filled())
        XCTAssertGreaterThan(fresh.fedFrames, 0, "the mic feeds the fresh home recognizer")
        XCTAssertEqual(dead.fedFrames, 0)
        await until { dead.stopped }
        XCTAssertTrue(dead.stopped)
    }

    func testHintsGoToTheirRecognizer() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.setHints(["Chợ Bến Thành"])
        XCTAssertEqual(x.hints.last, ["Chợ Bến Thành"])
    }
}

private extension AVAudioPCMBuffer {
    func filled() -> AVAudioPCMBuffer {
        frameLength = frameCapacity
        return self
    }
}
