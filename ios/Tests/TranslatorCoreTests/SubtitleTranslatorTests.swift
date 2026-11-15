import Foundation
import Testing
@testable import TranslatorCore

/// A fake translator: upper-cases the text after a delay and records every request
actor FakeTranslator {
    private(set) var requests: [String] = []
    let delay: Duration
    var failing: Set<String> = []

    init(delay: Duration = .milliseconds(5)) { self.delay = delay }

    func fail(on text: String) { failing.insert(text) }

    func translate(_ text: String) async throws -> String {
        requests.append(text)
        try await Task.sleep(for: delay)
        if failing.contains(text) { throw CancellationError() }
        return text.uppercased()
    }
}

@MainActor
final class Results {
    var byTurn: [Int: String] = [:]
}

@MainActor
@Suite struct SubtitleTranslatorTests {
    // No fixed waits: `idle()` returns once every queued request has been handled, however loaded the machine is

    @Test func finalsAreTranslatedOnceAndJoined() async throws {
        let fake = FakeTranslator()
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.setPartial("xin", turn: 1)
        st.setPartial("xin chào", turn: 1)
        st.addFinal("xin chào", turn: 1)
        st.setPartial("", turn: 1)
        st.setPartial("anh", turn: 1)
        st.addFinal("anh khỏe không", turn: 1)
        st.setPartial("", turn: 1)
        await st.idle()
        #expect(results.byTurn[1] == "XIN CHÀO ANH KHỎE KHÔNG")
        let requests = await fake.requests
        // Each final once; partials only while current (latest wins)
        #expect(requests.filter { $0 == "xin chào" }.count <= 2)
        #expect(requests.filter { $0 == "anh khỏe không" }.count == 1)
    }

    /// The old latest-wins translator wrote every result into the last line: a phrase finalized just
    /// before a new turn started lost its translation in its own line
    @Test func lateFinalOfAnEarlierTurnLandsInThatTurn() async throws {
        let fake = FakeTranslator(delay: .milliseconds(50))
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.addFinal("một", turn: 1)
        st.addFinal("hai", turn: 1)
        st.setPartial("ba", turn: 2)
        await st.idle()
        #expect(results.byTurn[1] == "MỘT HAI")
        #expect(results.byTurn[2] == "BA")
    }

    @Test func aFailedTranslationKeepsTheVolatileEnglish() async throws {
        let fake = FakeTranslator()
        await fake.fail(on: "bốn năm")
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.setPartial("bốn", turn: 1)
        await st.idle()
        st.addFinal("bốn năm", turn: 1)
        await st.idle()
        #expect(results.byTurn[1] == "BỐN")
    }

    /// Requests stay one phrase long however long the turn gets
    @Test func requestLengthDoesNotGrowWithTheTurn() async throws {
        let fake = FakeTranslator(delay: .milliseconds(1))
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        for i in 0..<30 {
            st.setPartial("câu số \(i)", turn: 1)
            st.addFinal("câu số \(i) xong", turn: 1)
            await Task.yield()
        }
        await st.idle()
        let longest = await fake.requests.map(\.count).max() ?? 0
        #expect(longest <= "câu số 29 xong".count)
        #expect(results.byTurn[1]?.split(separator: " ").count == 30 * 4)
    }

    @Test func emptyPhrasesAreNotTranslated() async throws {
        let fake = FakeTranslator()
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.addFinal("một", turn: 1)
        st.addFinal("", turn: 1)
        st.addFinal("hai", turn: 1)
        await st.idle()
        #expect(await fake.requests.contains("") == false)
        #expect(results.byTurn[1] == "MỘT HAI")
    }

    @Test func resetDropsPendingWork() async throws {
        let fake = FakeTranslator(delay: .milliseconds(50))
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.addFinal("một", turn: 1)
        st.addFinal("hai", turn: 1)
        st.reset()
        await st.idle()
        #expect(results.byTurn[1] == nil || results.byTurn[1] == "")
    }

    // MARK: Refine step

    @Test func refinedFinalReplacesItsDraft() async throws {
        let fake = FakeTranslator()
        let results = Results()
        var history: [String] = []
        let st = SubtitleTranslator(translate: { try await fake.translate($0) },
                                    refine: { source, draft in source == "hai" ? "Two (refined)" : nil }) {
            results.byTurn[$0] = $1
            history.append($1)
        }
        st.addFinal("một", turn: 1)
        st.addFinal("hai", turn: 1)
        await st.idle()
        #expect(results.byTurn[1] == "MỘT Two (refined)")
        // The draft was shown first
        #expect(history.contains("MỘT HAI"))
    }

    @Test func slowRefineDoesNotHoldTheNextPhrase() async throws {
        let fake = FakeTranslator()
        let results = Results()
        let gate = AsyncGate()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) },
                                    refine: { _, draft in await gate.wait(); return draft + "!" }) {
            results.byTurn[$0] = $1
        }
        st.addFinal("một", turn: 1)
        st.addFinal("hai", turn: 1)
        // Both drafts arrive while the first refine is still waiting
        for _ in 0..<200 where results.byTurn[1] != "MỘT HAI" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(results.byTurn[1] == "MỘT HAI")
        await gate.open()
        await st.idle()
        #expect(results.byTurn[1] == "MỘT! HAI!")
    }

    @Test func refineAfterResetIsDropped() async throws {
        let fake = FakeTranslator()
        let results = Results()
        let gate = AsyncGate()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) },
                                    refine: { _, _ in await gate.wait(); return "late" }) { results.byTurn[$0] = $1 }
        st.addFinal("một", turn: 1)
        for _ in 0..<200 where results.byTurn[1] != "MỘT" { try await Task.sleep(for: .milliseconds(5)) }
        st.reset()
        results.byTurn[1] = nil
        await gate.open()
        await st.idle()
        #expect(results.byTurn[1] == nil)
    }
}

/// Holds callers until `open()`.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
