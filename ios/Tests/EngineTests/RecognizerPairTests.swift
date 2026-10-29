import AVFAudio
import Speech
import XCTest
@testable import TranslatorCore

// Moved from app/ios/RunnerTests/RecognizerPairTests.swift (Flutter engine, Track D re-entrancy fix): events now
// arrive on the Core streams and errors are `EngineError`.

@MainActor
final class RecognizerPairTests: XCTestCase {
    private let sink = EngineEventSink()
    private var recorder: EventRecorder!

    override func setUp() async throws {
        recorder = EventRecorder(sink)
    }

    private func pair(_ fakes: [String: FakeRecognizer]) -> RecognizerPair {
        RecognizerPair(events: sink, factory: { language in fakes[language] })
    }

    private func theirTexts() -> [String] {
        recorder.all.compactMap { if case .theirs(let m) = $0 { return "\(m.text)@\(m.generation)" } else { return nil } }
    }

    func testStopDuringStartLeavesNothingRunning() async {
        let x = FakeRecognizer("en", holdStart: true), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        let start = Task { try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: []) }
        await until { x.isHeld }
        XCTAssertTrue(x.isHeld, "start must be suspended in the board recognizer's start")
        engine.stop()
        x.release()
        let error = await engineError { _ = try await start.value }
        XCTAssertEqual(error, .notReady, "a start overtaken by stop must not report success")
        await settle()
        XCTAssertNil(engine.theirs)
        XCTAssertNil(engine.mine)
        XCTAssertNil(engine.pair)
        XCTAssertTrue(x.stopped, "what the stale start built must be stopped")
        XCTAssertFalse(home.started && !home.stopped, "home must not be left running")
        x.emit(.final("late", confidence: 0.9, audio: 1))
        await settle()
        XCTAssertEqual(theirTexts(), [])
    }

    func testSecondStartSupersedesTheFirst() async throws {
        let x1 = FakeRecognizer("en", holdStart: true), home1 = FakeRecognizer("vi")
        let x2 = FakeRecognizer("ja"), home2 = FakeRecognizer("vi")
        var homes = [home1, home2]
        let engine = RecognizerPair(events: sink, factory: { language in
            switch language {
            case "en": return x1
            case "ja": return x2
            default: return homes.isEmpty ? nil : homes.removeFirst()
            }
        })
        let first = Task { try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: []) }
        await until { x1.isHeld }
        XCTAssertTrue(x1.isHeld)
        let started = try await engine.start(PairMsg(home: "vi", other: "ja", generation: 2), hints: [])
        XCTAssertTrue(started)
        x1.release()
        let error = await engineError { _ = try await first.value }
        XCTAssertEqual(error, .notReady, "the superseded start must not report success")
        await settle()
        XCTAssertTrue(engine.theirs === x2)
        XCTAssertEqual(engine.pair?.generation, 2)
        XCTAssertTrue(x1.stopped, "the first start's recognizers are stopped")
        XCTAssertFalse(home1.started && !home1.stopped)
        x1.emit(.final("from the loser", confidence: 0.9, audio: 1))
        home1.emit(.final("loser mine", confidence: nil, audio: 1))
        x2.emit(.final("from the winner", confidence: 0.9, audio: 1))
        await settle()
        XCTAssertEqual(theirTexts(), ["from the winner@2"])
        XCTAssertFalse(recorder.all.contains { if case .mine = $0 { return true } else { return false } })
    }

    func testSameLanguagesOnlyUpdateTheGeneration() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        let fresh = try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: [])
        let again = try await engine.start(PairMsg(home: "vi", other: "en", generation: 5), hints: ["Bến Thành"])
        XCTAssertTrue(fresh)
        XCTAssertFalse(again)
        XCTAssertFalse(x.stopped)
        XCTAssertEqual(x.hints.last, ["Bến Thành"], "a same-language start updates the hints")
        x.emit(.final("hello", confidence: 0.8, audio: 1))
        await settle()
        XCTAssertEqual(theirTexts(), ["hello@5"])
    }

    func testStopSilencesTheRunningRecognizers() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        _ = try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: [])
        engine.stop()
        await settle()
        XCTAssertTrue(x.stopped && home.stopped)
        x.emit(.final("after stop", confidence: 0.9, audio: 1))
        await settle()
        XCTAssertEqual(theirTexts(), [])
    }

    func testMissingRecognizerIsNotReady() async {
        let engine = pair(["vi": FakeRecognizer("vi")])
        let error = await engineError { _ = try await engine.start(PairMsg(home: "vi", other: "xx", generation: 1), hints: []) }
        XCTAssertEqual(error, .notReady)
        XCTAssertFalse(engine.isRunning)
    }

    func testMineResultsAreMappedWithTheirTimes() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        _ = try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: [])
        home.emit(.partial("xin", audio: 0.5))
        home.emit(.final("xin chào", confidence: nil, audio: 1))
        await settle()
        let mine = recorder.all.compactMap { if case .mine(let m) = $0 { return m } else { return nil } }
        XCTAssertEqual(mine.map(\.kind), [.partial, .finalText])
        XCTAssertEqual(mine.map(\.text), ["xin", "xin chào"])
        XCTAssertEqual(mine.map { $0.endMs - $0.startMs }, [500, 1000])
    }
}
