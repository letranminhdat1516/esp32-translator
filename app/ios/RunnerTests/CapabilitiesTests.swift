import Speech
import Translation
import XCTest
@testable import Runner

final class CapabilitiesAssemblyTests: XCTestCase {
    func testOnDeviceRecognizersPerLanguageFromBothTranscribers() {
        let caps = CapabilitiesAssembly.assemble(
            home: "vi",
            speechLocales: [Locale(identifier: "en_US"), Locale(identifier: "en_GB"), Locale(identifier: "ja_JP")],
            dictationLocales: [Locale(identifier: "vi_VN"), Locale(identifier: "en_US")],
            translation: [:], voices: [])
        XCTAssertEqual(caps.recognizers, [
            RecognizerEntryMsg(language: "en", kinds: ["osOnDevice"]),
            RecognizerEntryMsg(language: "ja", kinds: ["osOnDevice"]),
            RecognizerEntryMsg(language: "vi", kinds: ["osOnDevice"]),
        ])
    }

    func testTranslatableNeedsBothDirectionsWithHome() {
        let caps = CapabilitiesAssembly.assemble(
            home: "vi", speechLocales: [], dictationLocales: [],
            translation: [
                "en": (toHome: .installed, fromHome: .supported),
                "ja": (toHome: .supported, fromHome: .unsupported),
                "ko": (toHome: .supported, fromHome: .supported),
            ],
            voices: [])
        // Home is listed once anything translates with it
        XCTAssertEqual(caps.translatable, ["en", "ko", "vi"])
    }

    func testNothingTranslatableLeavesHomeOut() {
        let caps = CapabilitiesAssembly.assemble(home: "vi", speechLocales: [], dictationLocales: [],
                                                 translation: ["ja": (toHome: .unsupported, fromHome: .unsupported)],
                                                 voices: [])
        XCTAssertEqual(caps.translatable, [])
    }

    func testVietnameseVoiceFromTheVoiceLanguages() {
        func caps(_ voices: [String]) -> CapabilitiesMsg {
            CapabilitiesAssembly.assemble(home: "vi", speechLocales: [], dictationLocales: [], translation: [:],
                                          voices: voices)
        }
        XCTAssertTrue(caps(["en-US", "vi-VN"]).vietnameseVoice)
        XCTAssertFalse(caps(["en-US", "ja-JP"]).vietnameseVoice)
    }
}

final class MissingAssemblyTests: XCTestCase {
    private let pair = PairMsg(home: "vi", other: "en", generation: 3)

    func testEverythingInstalledIsNothingMissing() {
        let missing = MissingAssembly.assemble(
            pair: pair, speech: [("en", .installed), ("vi", .installed)],
            translation: [("en", "vi", .installed), ("vi", "en", .installed)], hasVoice: true)
        XCTAssertEqual(missing, [])
    }

    func testDownloadableItemsAreMissingInOrder() {
        let missing = MissingAssembly.assemble(
            pair: pair, speech: [("en", .supported), ("vi", .downloading)],
            translation: [("en", "vi", .supported), ("vi", "en", .installed)], hasVoice: false)
        XCTAssertEqual(missing, [
            MissingMsg(kind: .speechModel, language: "en"),
            MissingMsg(kind: .speechModel, language: "vi"),
            MissingMsg(kind: .translation, language: "en", from: "en", to: "vi"),
            MissingMsg(kind: .ttsVoice, language: "vi"),
        ])
    }

    func testUnsupportedItemsAreNotOfferedAsDownloads() {
        let missing = MissingAssembly.assemble(
            pair: pair, speech: [("en", nil), ("vi", .unsupported)],
            translation: [("en", "vi", .unsupported)], hasVoice: true)
        XCTAssertEqual(missing, [])
    }
}

@MainActor
final class DownloadsTests: XCTestCase {
    private struct Cancelled: Error {}

    private func recorder() -> (EventQueue, () -> [DownloadMsg]) {
        var got: [DownloadMsg] = []
        let queue = EventQueue { event in
            if case .download(let msg) = event { got.append(msg) }
        }
        return (queue, { got })
    }

    private func settle() async {
        // The event queue delivers on the main actor after the call returns
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testTranslationDownloadReportsStartThenDone() async throws {
        let (queue, got) = recorder()
        var asked: [String] = []
        var refreshed = 0
        let downloads = Downloads(events: queue, home: { "vi" }, work: .init(
            translation: { from, to in asked.append("\(from)>\(to)") },
            speech: { _, _ in XCTFail("not a speech item") },
            voice: { XCTFail("not a voice item") }),
            onDone: { refreshed += 1 })
        let item = MissingMsg(kind: .translation, language: "en", from: "en", to: "vi")
        try await downloads.download(item)
        await settle()
        XCTAssertEqual(asked, ["en>vi"])
        XCTAssertEqual(got(), [DownloadMsg(item: item, progress: 0, done: false),
                               DownloadMsg(item: item, progress: 1, done: true)])
        XCTAssertEqual(refreshed, 1)
    }

    func testTranslationWithoutDirectionPairsTheLanguageWithHome() async throws {
        var asked: [String] = []
        let downloads = Downloads(events: EventQueue { _ in }, home: { "vi" }, work: .init(
            translation: { from, to in asked.append("\(from)>\(to)") }, speech: { _, _ in }, voice: {}),
            onDone: {})
        try await downloads.download(MissingMsg(kind: .translation, language: "ja"))
        XCTAssertEqual(asked, ["vi>ja"])
    }

    /// The Swift app's 3f23288 bug: a cancelled sheet must be an error, never "done"
    func testCancelledDownloadEmitsAnErrorAndThrowsDownloadFailed() async {
        let (queue, got) = recorder()
        var refreshed = 0
        let downloads = Downloads(events: queue, home: { "vi" }, work: .init(
            translation: { _, _ in throw Cancelled() }, speech: { _, _ in }, voice: {}),
            onDone: { refreshed += 1 })
        let item = MissingMsg(kind: .translation, language: "en", from: "vi", to: "en")
        do {
            try await downloads.download(item)
            XCTFail("a cancelled download must throw")
        } catch let error as PigeonError {
            XCTAssertEqual(error.code, "downloadFailed")
        } catch {
            XCTFail("unexpected \(error)")
        }
        await settle()
        let events = got()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.done, true)
        XCTAssertNotNil(events.last?.error)
        XCTAssertFalse(events.contains { $0.done && $0.error == nil })
        XCTAssertEqual(refreshed, 1, "capabilities are re-read after a failed download too")
    }

    func testSpeechDownloadForwardsProgress() async throws {
        let (queue, got) = recorder()
        let downloads = Downloads(events: queue, home: { "vi" }, work: .init(
            translation: { _, _ in },
            speech: { language, progress in
                XCTAssertEqual(language, "en")
                progress(0.5)
            },
            voice: {}),
            onDone: {})
        let item = MissingMsg(kind: .speechModel, language: "en")
        try await downloads.download(item)
        await settle()
        XCTAssertEqual(got().map(\.progress), [0, 0.5, 1])
        XCTAssertEqual(got().map(\.done), [false, false, true])
    }

    func testVoiceItemOpensTheSystemSettingsAndReportsDone() async throws {
        let (queue, got) = recorder()
        var opened = 0
        let downloads = Downloads(events: queue, home: { "vi" }, work: .init(
            translation: { _, _ in }, speech: { _, _ in }, voice: { opened += 1 }), onDone: {})
        try await downloads.download(MissingMsg(kind: .ttsVoice, language: "vi"))
        await settle()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(got().last?.done, true)
    }
}

/// The real frameworks on the host: the synchronous pigeon calls (capabilities, missing) block their caller
/// while the framework queries run detached; they must answer instead of deadlocking or timing out
@MainActor
final class CapabilitiesLiveTests: XCTestCase {
    func testCapabilitiesAnswerFromTheMainThread() throws {
        let started = Date()
        let caps = try XCTUnwrap(CapabilitiesCache().get(home: "vi", timeout: 20))
        print("live capabilities after \(Date().timeIntervalSince(started)) s: \(caps.recognizers.count) recognizer languages, translatable \(caps.translatable), vietnameseVoice \(caps.vietnameseVoice)")
        XCTAssertTrue(caps.recognizers.allSatisfy { $0.kinds == ["osOnDevice"] }, "\(caps)")
    }

    func testMissingAnswersFromTheMainThread() throws {
        let pair = PairMsg(home: "vi", other: "en", generation: 1)
        let started = Date()
        let missing = try XCTUnwrap(Blocking.run(timeout: 20) { await MissingAssembly.gather(pair) })
        print("live missing for vi/en after \(Date().timeIntervalSince(started)) s: \(missing)")
    }
}

/// The cache behind the synchronous `capabilities()`: bounded waits, one gather in flight, no stale results
final class CapabilitiesCacheTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        let release = DispatchSemaphore(value: 0)
    }

    private func caps(_ translatable: [String]) -> CapabilitiesMsg {
        CapabilitiesMsg(recognizers: [], translatable: translatable, vietnameseVoice: true)
    }

    func testASlowGatherTimesOutThenServesTheSameGathersResult() {
        let gate = Gate()
        let cache = CapabilitiesCache { _ in
            gate.lock.withLock { gate.calls += 1 }
            await Task.detached { gate.release.wait() }.value
            return CapabilitiesMsg(recognizers: [], translatable: ["en"], vietnameseVoice: true)
        }
        XCTAssertNil(cache.get(home: "vi", timeout: 0.1), "a cold gather must not block past the timeout")
        gate.release.signal()
        XCTAssertEqual(cache.get(home: "vi", timeout: 2), caps(["en"]))
        XCTAssertEqual(gate.lock.withLock { gate.calls }, 1, "the timed-out call must not start a second gather")
    }

    func testInvalidateDropsAResultGatheredBeforeIt() {
        let gate = Gate()
        let cache = CapabilitiesCache { _ in
            let n = gate.lock.withLock { gate.calls += 1; return gate.calls }
            if n == 1 { await Task.detached { gate.release.wait() }.value }
            return CapabilitiesMsg(recognizers: [], translatable: n == 1 ? ["stale"] : ["fresh"], vietnameseVoice: true)
        }
        cache.refresh(home: "vi")
        Thread.sleep(forTimeInterval: 0.05)
        cache.invalidate()  // a download finished while the first gather was running
        cache.refresh(home: "vi")
        XCTAssertEqual(cache.get(home: "vi", timeout: 2), caps(["fresh"]))
        gate.release.signal()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(cache.get(home: "vi", timeout: 2), caps(["fresh"]), "the stale gather must not overwrite")
    }
}
