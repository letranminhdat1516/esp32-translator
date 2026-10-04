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
    func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

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
        try await settle()
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
        try await Task.sleep(for: .milliseconds(400))
        #expect(results.byTurn[1] == "MỘT HAI")
        #expect(results.byTurn[2] == "BA")
    }

    @Test func aFailedTranslationKeepsTheVolatileEnglish() async throws {
        let fake = FakeTranslator()
        await fake.fail(on: "bốn năm")
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        st.setPartial("bốn", turn: 1)
        try await settle()
        st.addFinal("bốn năm", turn: 1)
        try await settle()
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
            try await Task.sleep(for: .milliseconds(5))
        }
        try await settle()
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
        try await settle()
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(results.byTurn[1] == nil || results.byTurn[1] == "")
    }
}
