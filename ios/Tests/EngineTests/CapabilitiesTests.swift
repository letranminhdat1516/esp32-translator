import Speech
import Translation
import XCTest
@testable import TranslatorCore

// Moved from app/ios/RunnerTests/CapabilitiesTests.swift, with the async capabilities(home) cache of the
// never-merged P2.0a change (branch worktree-agent-a2a8ea34f2a9a1746). CapabilitiesLiveTests ask the real
// frameworks on the Mac.

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
    private struct Described: LocalizedError {
        var errorDescription: String? { "The network connection was lost." }
    }

    /// `DownloadMsg.error` is readable text: the reason of a DownloadFailure, "cancelled", or the error's
    /// localized description, never `String(describing:)` ("Cancelled()")
    func testDownloadErrorMessagesAreReadable() {
        XCTAssertEqual(Downloads.message(for: DownloadFailure("no window to show the download sheet")),
                       "no window to show the download sheet")
        XCTAssertEqual(Downloads.message(for: CancellationError()), "cancelled")
        XCTAssertEqual(Downloads.message(for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)),
                       "cancelled")
        XCTAssertEqual(Downloads.message(for: Described()), "The network connection was lost.")
    }

    private func recorder() -> (EngineEventSink, () -> [DownloadMsg]) {
        let sink = EngineEventSink()
        let recorder = EventRecorder(sink)
        return (sink, { recorder.all.compactMap { if case .download(let m) = $0 { return m } else { return nil } } })
    }

    func testTranslationDownloadReportsStartThenDone() async throws {
        let (queue, got) = recorder()
        var asked: [String] = []
        var refreshed = 0
        let downloads = Downloads(events: queue, work: .init(
            translation: { from, to in asked.append("\(from)>\(to)") },
            speech: { _, _ in XCTFail("not a speech item") },
            voice: { XCTFail("not a voice item") }),
            onDone: { refreshed += 1 })
        let item = MissingMsg(kind: .translation, language: "en", from: "en", to: "vi")
        try await downloads.download(item)
        await until { got().count >= 2 }
        XCTAssertEqual(asked, ["en>vi"])
        XCTAssertEqual(got(), [DownloadMsg(item: item, progress: 0, done: false),
                               DownloadMsg(item: item, progress: 1, done: true)])
        XCTAssertEqual(refreshed, 1)
    }

    /// The engine knows no home language of its own: `missing()` always names both sides of a translation item
    func testTranslationWithoutDirectionFailsInsteadOfGuessingHome() async {
        var asked: [String] = []
        let downloads = Downloads(events: EngineEventSink(), work: .init(
            translation: { from, to in asked.append("\(from)>\(to)") }, speech: { _, _ in }, voice: {}),
            onDone: {})
        do {
            try await downloads.download(MissingMsg(kind: .translation, language: "ja"))
            XCTFail("an item without a source language must throw")
        } catch let error as EngineError {
            XCTAssertEqual(error, .downloadFailed)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(asked, [])
    }

    /// The Swift app's 3f23288 bug: a cancelled sheet must be an error, never "done"
    func testCancelledDownloadEmitsAnErrorAndThrowsDownloadFailed() async {
        let (queue, got) = recorder()
        var refreshed = 0
        let downloads = Downloads(events: queue, work: .init(
            translation: { _, _ in throw CancellationError() }, speech: { _, _ in }, voice: {}),
            onDone: { refreshed += 1 })
        let item = MissingMsg(kind: .translation, language: "en", from: "vi", to: "en")
        do {
            try await downloads.download(item)
            XCTFail("a cancelled download must throw")
        } catch let error as EngineError {
            XCTAssertEqual(error, .downloadFailed)
        } catch {
            XCTFail("unexpected \(error)")
        }
        await until { got().count >= 2 }
        let events = got()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.done, true)
        XCTAssertEqual(events.last?.error, "cancelled", "a readable reason, not a Swift dump")
        XCTAssertFalse(events.contains { $0.done && $0.error == nil })
        XCTAssertEqual(refreshed, 1, "capabilities are re-read after a failed download too")
    }

    func testSpeechDownloadForwardsProgress() async throws {
        let (queue, got) = recorder()
        let downloads = Downloads(events: queue, work: .init(
            translation: { _, _ in },
            speech: { language, progress in
                XCTAssertEqual(language, "en")
                progress(0.5)
            },
            voice: {}),
            onDone: {})
        let item = MissingMsg(kind: .speechModel, language: "en")
        try await downloads.download(item)
        await until { got().count >= 3 }
        XCTAssertEqual(got().map(\.progress), [0, 0.5, 1])
        XCTAssertEqual(got().map(\.done), [false, false, true])
    }

    func testVoiceItemOpensTheSystemSettingsAndReportsDone() async throws {
        let (queue, got) = recorder()
        var opened = 0
        let downloads = Downloads(events: queue, work: .init(
            translation: { _, _ in }, speech: { _, _ in }, voice: { opened += 1 }), onDone: {})
        try await downloads.download(MissingMsg(kind: .ttsVoice, language: "vi"))
        await until { got().count >= 2 }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(got().last?.done, true)
    }
}

/// The real frameworks on the host: the async calls (capabilities, missing) answer from the framework
/// queries instead of deadlocking
final class CapabilitiesLiveTests: XCTestCase {
    func testCapabilitiesAnswer() async {
        let started = Date()
        let caps = await CapabilitiesCache().get(home: "vi")
        print("live capabilities after \(Date().timeIntervalSince(started)) s: \(caps.recognizers.count) recognizer languages, translatable \(caps.translatable), vietnameseVoice \(caps.vietnameseVoice)")
        XCTAssertTrue(caps.recognizers.allSatisfy { $0.kinds == ["osOnDevice"] }, "\(caps)")
    }

    func testMissingAnswers() async {
        let pair = PairMsg(home: "vi", other: "en", generation: 1)
        let started = Date()
        let missing = await MissingAssembly.gather(pair)
        print("live missing for vi/en after \(Date().timeIntervalSince(started)) s: \(missing)")
    }
}

/// The cache behind the async `capabilities(home)`: callers wait without blocking, one gather in flight per home,
/// no stale results
final class CapabilitiesCacheTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var homes: [String] = []
        var calls: Int { lock.withLock { homes.count } }
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Suspends until `release()` (no thread is blocked)
        func held() async {
            await withCheckedContinuation { c in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    waiters.append(c)
                    return false
                }
                if now { c.resume() }
            }
        }

        func release() {
            let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released = true
                defer { waiters = [] }
                return waiters
            }
            w.forEach { $0.resume() }
        }
    }

    private func caps(_ translatable: [String]) -> CapabilitiesMsg {
        CapabilitiesMsg(recognizers: [], translatable: translatable, vietnameseVoice: true)
    }

    func testASlowGatherDoesNotBlockAndEveryCallerGetsItsResult() async {
        let gate = Gate()
        let cache = CapabilitiesCache { home in
            gate.lock.withLock { gate.homes.append(home) }
            await gate.held()
            return CapabilitiesMsg(recognizers: [], translatable: ["en"], vietnameseVoice: true)
        }
        let first = Task { await cache.get(home: "vi") }
        let second = Task { await cache.get(home: "vi") }
        await eventually { gate.calls >= 1 }
        try? await Task.sleep(for: .milliseconds(100))
        // Both callers are suspended (no thread blocked) on the one gather in flight
        XCTAssertEqual(gate.calls, 1, "the second caller joins the gather in flight")
        gate.release()
        let a = await first.value, b = await second.value
        XCTAssertEqual(a, caps(["en"]))
        XCTAssertEqual(b, caps(["en"]))
        let got1 = await cache.get(home: "vi")
        XCTAssertEqual(got1, caps(["en"]), "then served from the cache")
        XCTAssertEqual(gate.calls, 1)
    }

    func testTheGatherGetsTheCallersHome() async {
        let gate = Gate()
        let cache = CapabilitiesCache { home in
            gate.lock.withLock { gate.homes.append(home) }
            return CapabilitiesMsg(recognizers: [], translatable: [home], vietnameseVoice: true)
        }
        let got2 = await cache.get(home: "ja")
        XCTAssertEqual(got2, caps(["ja"]))
        let got3 = await cache.get(home: "vi")
        XCTAssertEqual(got3, caps(["vi"]), "another home is gathered anew")
        XCTAssertEqual(gate.lock.withLock { gate.homes }, ["ja", "vi"])
    }

    func testInvalidateDropsAResultGatheredBeforeIt() async {
        let gate = Gate()
        let cache = CapabilitiesCache { home in
            let n = gate.lock.withLock { gate.homes.append(home); return gate.homes.count }
            if n == 1 { await gate.held() }
            return CapabilitiesMsg(recognizers: [], translatable: n == 1 ? ["stale"] : ["fresh"], vietnameseVoice: true)
        }
        cache.refresh(home: "vi")
        await eventually { gate.calls >= 1 }  // the first gather is running
        cache.invalidate()  // a download finished while the first gather was running
        cache.refresh(home: "vi")
        let got4 = await cache.get(home: "vi")
        XCTAssertEqual(got4, caps(["fresh"]))
        gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        let got5 = await cache.get(home: "vi")
        XCTAssertEqual(got5, caps(["fresh"]), "the stale gather must not overwrite")
    }
}
