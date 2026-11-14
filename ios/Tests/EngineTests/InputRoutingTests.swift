import AVFAudio
import XCTest
@testable import TranslatorCore

/// Phone-only routing (ARCHITECTURE §5): the pure route decisions, and AppleVoiceEngine wiring the mic to the right
/// recognizer for each route while board mode stays exactly as before.
final class InputRoutePlanTests: XCTestCase {
    func testBoardModeIsTheOldSessionWhateverElseHolds() {
        for held in [false, true] {
            for headset in [false, true] {
                XCTAssertEqual(InputRoute.plan(mode: .board, talkHeld: held, headsetConnected: headset), .board)
            }
        }
        XCTAssertEqual(InputRoute.board.target, .mine)
        XCTAssertEqual(InputRoute.board.preferredInput, .automatic)
        XCTAssertEqual(InputRoute.board.bluetooth, .hfp)
        XCTAssertTrue(InputRoute.board.gated)
        XCTAssertTrue(InputRoute.board.voiceChatMode)
        XCTAssertFalse(InputRoute.board.defaultToSpeaker)
    }

    func testPhoneOnlyIdleTheIPhoneMicHearsThemAndTheEarbudsStayOutput() {
        for headset in [false, true] {
            let r = InputRoute.plan(mode: .phoneOnly, talkHeld: false, headsetConnected: headset)
            XCTAssertEqual(r.target, .theirs)
            XCTAssertEqual(r.preferredInput, .builtInMic)
            XCTAssertEqual(r.bluetooth, .a2dp, "AirPods stay connected as (A2DP) output")
            XCTAssertFalse(r.voiceChatMode, "voice chat would pull the AirPods into HFP")
            XCTAssertFalse(r.gated, "the other person is not the wearer")
            XCTAssertTrue(r.defaultToSpeaker, "without earbuds speech plays on the loudspeaker")
        }
    }

    func testHoldToTalkWithAHeadsetUsesItsMic() {
        let r = InputRoute.plan(mode: .phoneOnly, talkHeld: true, headsetConnected: true)
        XCTAssertEqual(r.target, .mine)
        XCTAssertEqual(r.preferredInput, .headset)
        XCTAssertEqual(r.bluetooth, .hfp)
        XCTAssertTrue(r.voiceChatMode)
        XCTAssertFalse(r.gated, "holding the button says you are speaking")
    }

    func testHoldToTalkWithoutAHeadsetUsesTheIPhoneMicForYou() {
        let r = InputRoute.plan(mode: .phoneOnly, talkHeld: true, headsetConnected: false)
        XCTAssertEqual(r.target, .mine)
        XCTAssertEqual(r.preferredInput, .builtInMic)
        XCTAssertFalse(r.gated)
        XCTAssertTrue(r.defaultToSpeaker)
    }
}

@MainActor
final class EngineInputRoutingTests: XCTestCase {
    private let enVi = PairMsg(home: "vi", other: "en", generation: 1)
    private let onDevice = RecognizerKind.osOnDevice.rawValue

    private func started(_ x: FakeRecognizer, _ home: FakeRecognizer) async throws -> EngineRig {
        let r = EngineRig(["en": [x], "vi": [home]])
        try await r.engine.start(pair: enVi, recognizerX: onDevice, hints: [])
        return r
    }

    private func buffer(_ frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
                                 frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        return b
    }

    func testBoardModeMicIsGatedAndFeedsMineAsBefore() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let r = try await started(x, home)
        try await r.engine.micOn(true)
        XCTAssertEqual(Array(r.log.calls.suffix(3)), ["session.configure", "mic.make", "session.stopSilence"])
        XCTAssertEqual(r.session.routes, [.board])
        XCTAssertEqual(r.micGated, [true])
        r.mics.last?.sink(buffer(160))
        XCTAssertEqual(home.fedFrames, 160)
        XCTAssertEqual(x.fedFrames, 0)
    }

    func testTalkHeldIsIgnoredInBoardMode() async throws {
        let r = try await started(FakeRecognizer("en"), FakeRecognizer("vi"))
        try await r.engine.micOn(true)
        try await r.engine.setTalkHeld(true)
        XCTAssertEqual(r.mics.count, 1, "nothing is retaken")
        XCTAssertEqual(r.session.routes, [.board])
    }

    func testPhoneOnlyFeedsTheIPhoneMicToTheirRecognizerNeverFinalized() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let r = try await started(x, home)
        try await r.engine.setInputMode(.phoneOnly)
        XCTAssertTrue(r.mics.isEmpty, "the mode alone takes no mic")
        try await r.engine.micOn(true)
        XCTAssertEqual(r.session.routes.last?.target, .theirs)
        XCTAssertEqual(r.micGated, [false])
        let mic = try XCTUnwrap(r.mics.last)
        mic.sink(buffer(320))
        await until { x.fedFrames >= 320 }
        XCTAssertGreaterThanOrEqual(x.fedFrames, 320, "fed on the main actor, like board audio")
        XCTAssertEqual(home.fedFrames, 0)
        mic.onFinalize()
        mic.onSpeechEnd()
        XCTAssertEqual(x.finalized, 0, "their recognizer is never finalized")
        XCTAssertEqual(home.finalized, 0)
    }

    func testHoldToTalkMovesTheInputToYouAndBackFinalizingOnRelease() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let r = try await started(x, home)
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.setInputMode(.phoneOnly)
        try await r.engine.micOn(true)
        let theirMic = try XCTUnwrap(r.mics.last)

        try await r.engine.setTalkHeld(true)
        XCTAssertTrue(theirMic.stopped)
        XCTAssertEqual(r.session.routes.last, InputRoute.plan(mode: .phoneOnly, talkHeld: true, headsetConnected: true))
        XCTAssertEqual(r.log.calls.filter { $0.hasPrefix("session.configure") }.suffix(2),
                       ["session.configure theirs", "session.configure mine"])
        XCTAssertEqual(r.micGated, [false, false])
        let myMic = try XCTUnwrap(r.mics.last)
        myMic.onSpeechStart()
        myMic.sink(buffer(160))
        XCTAssertEqual(home.fedFrames, 160)

        try await r.engine.setTalkHeld(false)
        XCTAssertTrue(myMic.stopped)
        XCTAssertEqual(r.session.routes.last?.target, .theirs)
        // The fake mic does not call its own stop callbacks; the real MicSource finalizes on stop (MicSource.stop)
        myMic.onFinalize()
        XCTAssertEqual(home.finalized, 1)
        await until { recorder.all.contains(.gate(true)) }
        XCTAssertTrue(recorder.all.contains(.gate(true)))
    }

    func testHoldToTalkWithoutAHeadsetStaysOnTheIPhoneMic() async throws {
        let r = try await started(FakeRecognizer("en"), FakeRecognizer("vi"))
        r.session.headsetConnected = false
        try await r.engine.setInputMode(.phoneOnly)
        try await r.engine.micOn(true)
        try await r.engine.setTalkHeld(true)
        XCTAssertEqual(r.session.routes.last?.preferredInput, .builtInMic)
        XCTAssertEqual(r.session.routes.last?.target, .mine)
    }

    func testBackToBoardModeRetakesTheGatedMicAndDropsTheHold() async throws {
        let r = try await started(FakeRecognizer("en"), FakeRecognizer("vi"))
        try await r.engine.setInputMode(.phoneOnly)
        try await r.engine.micOn(true)
        try await r.engine.setTalkHeld(true)
        try await r.engine.setInputMode(.board)
        XCTAssertEqual(r.session.routes.last, .board)
        XCTAssertEqual(r.micGated.last, true)
        // A later hold in board mode does nothing
        let mics = r.mics.count
        try await r.engine.setTalkHeld(true)
        XCTAssertEqual(r.mics.count, mics)
    }

    func testARerouteThatFailsLeavesTheEngineIdleAndReportsIt() async throws {
        let r = try await started(FakeRecognizer("en"), FakeRecognizer("vi"))
        let recorder = EventRecorder(r.engine.events())
        try await r.engine.micOn(true)
        r.session.failConfigure = true
        try await r.engine.setInputMode(.phoneOnly)
        await until { recorder.all.contains(.audioSession(AudioSessionMsg(kind: .interrupted))) }
        XCTAssertTrue(recorder.all.contains(.audioSession(AudioSessionMsg(kind: .interrupted))))
        XCTAssertEqual(r.log.calls.last, "session.startSilence")
    }
}
