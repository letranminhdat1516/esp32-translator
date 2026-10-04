import Foundation
import Testing
@testable import TranslatorCore

/// Recorded recognizer events (ios/Tools/vi-harness, DictationTranscriber vi-VN, real-time)
func recordedEvents(_ name: String) throws -> [(Double, TranscriptEvent)] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
        let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let text = d["text"] as! String
        let event: TranscriptEvent = d["kind"] as! String == "final" ? .final(text, confidence: nil) : .partial(text)
        return (d["t"] as! Double, event)
    }
}

/// Lines the "You say" panel shows after replaying events
func replay(_ events: [(Double, TranscriptEvent)]) -> [String] {
    var assembler = TurnAssembler()
    var lines: [Int: String] = [:]
    var order: [Int] = []
    let t0 = Date()
    for (t, e) in events {
        guard assembler.handle(e, at: t0.addingTimeInterval(t)) != nil, let turn = assembler.turn else { continue }
        if lines[turn.id] == nil { order.append(turn.id) }
        lines[turn.id] = turn.text
    }
    return order.map { lines[$0]! }
}

@Suite struct TurnAssemblerTests {
    /// The recognizer went quiet for 2.2 s while a phrase was still volatile (a bystander spoke after the
    /// user). The old assembly started a new line there: the first line kept the stale volatile text and
    /// the second repeated the whole phrase.
    @Test func doesNotSplitAPhraseThatIsStillVolatile() throws {
        let events = try recordedEvents("split_byst12_s20")
        let lines = replay(events)
        #expect(lines.count == 1)
        guard case .final(let final, _) = events.last!.1 else { Issue.record("no final"); return }
        #expect(lines.first == final)
    }

    /// A 42 s monologue with pauses of 0.4–1.9 s: one turn, every finalized word kept, in order
    @Test func longMonologueKeepsEveryWord() throws {
        let events = try recordedEvents("long_monologue")
        let finals = events.compactMap { e -> String? in
            if case .final(let t, _) = e.1 { return t.trimmingCharacters(in: .whitespaces) }
            return nil
        }
        let lines = replay(events)
        #expect(lines == [finals.joined(separator: " ")])
        #expect(lines.first?.split(separator: " ").count == 116)
    }

    @Test func pauseAfterAFinalStartsANewTurn() {
        var a = TurnAssembler(turnGap: 2)
        let t0 = Date()
        #expect(a.handle(.partial("xin chào"), at: t0)?.started == true)
        #expect(a.handle(.final("xin chào", confidence: nil), at: t0 + 1)?.final == "xin chào")
        // 1.5 s later: same turn
        #expect(a.handle(.partial("anh"), at: t0 + 2.5)?.started == false)
        #expect(a.handle(.final("anh khỏe không", confidence: nil), at: t0 + 3)?.started == false)
        #expect(a.turn?.text == "xin chào anh khỏe không")
        // 2.5 s after the final: new turn
        #expect(a.handle(.partial("cảm ơn"), at: t0 + 5.5)?.started == true)
        #expect(a.turn?.text == "cảm ơn")
    }

    @Test func waitsForAVolatilePhraseButNotForever() {
        var a = TurnAssembler(turnGap: 2, staleGap: 10)
        let t0 = Date()
        _ = a.handle(.partial("một hai"), at: t0)
        #expect(a.handle(.partial("một hai ba"), at: t0 + 3)?.started == false)
        #expect(a.handle(.partial("bốn"), at: t0 + 14)?.started == true)
    }

    @Test func emptyResultClearsTheVolatileText() {
        var a = TurnAssembler()
        let t0 = Date()
        _ = a.handle(.final("chào", confidence: nil), at: t0)
        _ = a.handle(.partial("ừm"), at: t0 + 0.5)
        #expect(a.handle(.final("", confidence: nil), at: t0 + 1) != nil)
        #expect(a.turn?.text == "chào")
        #expect(a.handle(.partial(""), at: t0 + 1.2) == nil)
    }

    @Test func displayedTextHasLoanwordsFixed() {
        var a = TurnAssembler()
        _ = a.handle(.final("Mình nhắn tin qua giữa lo cho tiện nhé", confidence: nil), at: Date())
        #expect(a.turn?.text == "Mình nhắn tin qua Zalo cho tiện nhé")
    }
}
