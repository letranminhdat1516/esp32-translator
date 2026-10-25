import XCTest
@testable import Runner

/// The engine's guards, which need no mic, speech model or device: typed errors before `start`, and calls that
/// must stay harmless when nothing runs
@MainActor
final class VoiceEngineTests: XCTestCase {
    private func engine() -> VoiceEngine { VoiceEngine(events: EventQueue { _ in }) }

    private func code(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as PigeonError {
            return error.code
        } catch {
            return "\(error)"
        }
    }

    func testWhisperIsNotOfferedOnIOS() async {
        let e = engine()
        let pair = PairMsg(home: "vi", other: "en", generation: 1)
        let got = await code { try await e.start(pair, recognizer: "whisper", hints: []) }
        XCTAssertEqual(got, "notReady")
    }

    func testMicAndSpeechNeedAStartedEngine() async {
        let e = engine()
        let mic = await code { try e.micOn(true) }
        XCTAssertEqual(mic, "notReady")
        let speak = await code { try e.speak("xin chào", id: 1) }
        XCTAssertEqual(speak, "notReady")
    }

    func testIdleCallsAreHarmless() throws {
        let e = engine()
        e.feedTheirAudio(Data([0, 0, 1, 0]), sampleRate: 16_000)
        e.setHints(["Đà Nẵng"])
        e.stopSpeaking()
        try e.micOn(false)
        e.stop()
        e.stop()
    }
}
