import AVFAudio
import XCTest
@testable import TranslatorCore

/// AppleVoiceEngine on fakes (no mic, speech model, audio session or speech output): the guards before `start`,
/// start/stop re-entrancy, the warm-up order, a mic failure surfaced as an event, translation, speech events,
/// capabilities with the passed home, downloads, board audio and the audio-session reactions.
/// The first three tests come from app/ios/RunnerTests/VoiceEngineTests.swift.
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
        try await e.feedTheirAudio([0, 1], sampleRate: 16_000)
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
        mic.onSpeechEnd()
        await settle()
        XCTAssertEqual(home.finalized, 1, "the gate closing finalizes the phrase")
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
        await settle()
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

    func testInterruptionEndedResumesAWantedMic() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.interruptionBegan)
        r.session.onChange?(.interruptionEnded(shouldResume: true))
        await settle()
        XCTAssertEqual(r.mics.count, 2, "the mic is rebuilt")
        let sessionEvents = recorder.all.compactMap { if case .audioSession(let m) = $0 { return m } else { return nil } }
        XCTAssertEqual(sessionEvents, [AudioSessionMsg(kind: .interrupted),
                                       AudioSessionMsg(kind: .resumed, route: .headset)])
    }

    func testInterruptionEndedWithoutResumeReleasesTheMic() async throws {
        let r = rig()
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.micOn(true)
        r.session.onChange?(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(r.mics[0].stopped)
        XCTAssertEqual(r.mics.count, 1, "the mic is not grabbed back")
        XCTAssertEqual(Array(r.log.calls.suffix(2)), ["session.deactivate", "session.startSilence"])
    }

    func testRouteChangesAreReported() async throws {
        let r = rig()
        let recorder = EventRecorder(r.engine.events())
        r.session.onChange?(.routeChanged(.phoneMic))
        await settle()
        XCTAssertEqual(recorder.all, [.audioSession(AudioSessionMsg(kind: .routeChanged, route: .phoneMic))])
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
        await settle()
        XCTAssertEqual(recorder.all, [.ttsStart(7), .ttsEnd(7)])
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
        await settle()
        XCTAssertEqual(r.capabilityHomes.get, ["vi", "vi"])
    }

    func testDownloadFailureIsTypedAndReported() async throws {
        let r = rig()
        r.downloadWork.speech = { _, _ in throw DownloadFailure("no network") }
        let recorder = EventRecorder(r.engine.events())
        let item = MissingMsg(kind: .speechModel, language: "en")
        let error = await engineError { try await r.engine.downloadItem(item) }
        XCTAssertEqual(error, .downloadFailed)
        await settle()
        XCTAssertEqual(recorder.all.last, .download(DownloadMsg(item: item, progress: 0, done: true, error: "no network")))
    }

    // MARK: Board audio

    func testBoardAudioIsFedToTheirRecognizerAndFinalizedOnAPause() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        try await r.engine.feedTheirAudio([Int16](repeating: 0, count: 320), sampleRate: 16_000)
        XCTAssertEqual(x.fedFrames, 0, "audio before start is dropped")
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.feedTheirAudio([Int16](repeating: 100, count: 320), sampleRate: 16_000)
        XCTAssertGreaterThan(x.fedFrames, 0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(x.finalized, 1, "a pause in board audio finalizes the phrase")
    }

    func testHintsGoToTheirRecognizer() async throws {
        let x = FakeRecognizer("en")
        let r = rig(en: [x])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        try await r.engine.setHints(["Chợ Bến Thành"])
        XCTAssertEqual(x.hints.last, ["Chợ Bến Thành"])
    }
}
