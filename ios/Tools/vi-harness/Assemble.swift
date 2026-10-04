import Foundation

/// Replays recognizer events through the "You say" turn assembly
enum Harness {
    /// Old ConversationEngine.handleMine, verbatim logic with event times instead of Date()
    static func legacyLines(_ events: [(Double, TranscriptEvent)]) -> [String] {
        let turnGap = 2.0
        var lines: [String] = []
        var myPartial = ""
        var committed = ""
        var last = -1e9
        for (now, event) in events {
            let text: String
            switch event {
            case .partial(let t): text = t
            case .final(let t, _): text = t
            }
            guard !text.isEmpty else { myPartial = ""; continue }
            if now - last > turnGap { committed = ""; lines.append("") }
            last = now
            switch event {
            case .partial(let t): myPartial = t
            case .final(let t, _): myPartial = ""; committed = committed.isEmpty ? t : committed + " " + t
            }
            let turnText = [committed, myPartial].filter { !$0.isEmpty }.joined(separator: " ")
            if !lines.isEmpty { lines[lines.count - 1] = turnText }
        }
        return lines
    }

    /// The app's TurnAssembler: "You say" lines, and what the translator gets for each line
    static func lines(_ events: [(Double, TranscriptEvent)]) -> [(display: String, translation: String)] {
        var assembler = TurnAssembler()
        var lines: [Int: (String, [String])] = [:]
        var order: [Int] = []
        let t0 = Date()
        for (t, event) in events {
            guard let change = assembler.handle(event, at: t0.addingTimeInterval(t)), let turn = assembler.turn else { continue }
            if lines[turn.id] == nil { order.append(turn.id) }
            var line = lines[turn.id] ?? ("", [])
            line.0 = turn.text
            if let final = change.final { line.1.append(VietnameseFixup.forTranslation(final)) }
            lines[turn.id] = line
        }
        return order.map { (lines[$0]!.0, lines[$0]!.1.joined(separator: " / ")) }
    }

    static func assemble(_ events: [(Double, TranscriptEvent)]) -> (display: String, translationInput: String, legacy: String) {
        let l = lines(events)
        return (l.map(\.display).joined(separator: " | "), l.map(\.translation).joined(separator: " | "),
                legacyLines(events).joined(separator: " | "))
    }
}
