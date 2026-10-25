import AVFAudio
import Speech
import XCTest
@testable import Runner

/// A recognizer whose `start` can be held open, to suspend `RecognizerPair.start` at a chosen await
final class FakeRecognizer: Recognizer, @unchecked Sendable {
    let locale: Locale
    var audioFormat: AVAudioFormat? { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) }
    private let lock = NSLock()
    private var onEvent: (@Sendable (TranscriptEvent) -> Void)?
    private var gate: CheckedContinuation<Void, Never>?
    private let holdStart: Bool
    private(set) var started = false
    private(set) var stopped = false
    private(set) var entered = false

    init(_ language: String, holdStart: Bool = false) {
        locale = Locale(identifier: language)
        self.holdStart = holdStart
    }

    var assetStatus: AssetInventory.Status { get async { .installed } }

    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        lock.withLock { self.onEvent = onEvent; entered = true }
        if holdStart {
            await withCheckedContinuation { c in lock.withLock { gate = c } }
        }
        lock.withLock { started = true }
    }

    /// Lets a held `start` return
    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }
        c?.resume()
    }

    var isHeld: Bool { lock.withLock { gate != nil } }

    func emit(_ event: TranscriptEvent) { lock.withLock { onEvent }?(event) }

    func setHints(_ hints: [String]) async {}
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finalizeNow() {}
    func stop() async { lock.withLock { stopped = true } }
}

@MainActor
final class RecognizerPairTests: XCTestCase {
    private var delivered: [EngineEvent] = []

    private func pair(_ fakes: [String: FakeRecognizer]) -> RecognizerPair {
        RecognizerPair(events: EventQueue { [weak self] e in self?.delivered.append(e) },
                       factory: { language in fakes[language] })
    }

    private func until(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func theirTexts() -> [String] {
        delivered.compactMap { if case .theirs(let m) = $0 { return "\(m.text)@\(m.generation)" } else { return nil } }
    }

    func testStopDuringStartLeavesNothingRunning() async {
        let x = FakeRecognizer("en", holdStart: true), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        let start = Task { try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: []) }
        await until { x.isHeld }
        XCTAssertTrue(x.isHeld, "start must be suspended in the board recognizer's start")
        engine.stop()
        x.release()
        do {
            _ = try await start.value
            XCTFail("a start overtaken by stop must not report success")
        } catch let error as PigeonError {
            XCTAssertEqual(error.code, "notReady")
        } catch {
            XCTFail("unexpected \(error)")
        }
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
        let engine = RecognizerPair(events: EventQueue { [weak self] e in self?.delivered.append(e) },
                                    factory: { language in
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
        do {
            _ = try await first.value
            XCTFail("the superseded start must not report success")
        } catch let error as PigeonError {
            XCTAssertEqual(error.code, "notReady")
        }
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
        XCTAssertFalse(delivered.contains { if case .mine = $0 { return true } else { return false } })
    }

    func testSameLanguagesOnlyUpdateTheGeneration() async throws {
        let x = FakeRecognizer("en"), home = FakeRecognizer("vi")
        let engine = pair(["en": x, "vi": home])
        let fresh = try await engine.start(PairMsg(home: "vi", other: "en", generation: 1), hints: [])
        let again = try await engine.start(PairMsg(home: "vi", other: "en", generation: 5), hints: [])
        XCTAssertTrue(fresh)
        XCTAssertFalse(again)
        XCTAssertFalse(x.stopped)
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
}
