import Foundation
import Testing
@testable import ClaudeBoardCore

private func text(_ m: BoardMessage) -> String { String(data: m.encode().dropFirst(5), encoding: .utf8)! }

// MARK: Utf8

@Test func fitKeepsShortStringsAndCutsLongOnesWithEllipsis() {
    #expect(Utf8.fit("abc", maxBytes: 3) == "abc")
    #expect(Utf8.fit("abcdef", maxBytes: 5) == "ab…")
    let cut = Utf8.fit(String(repeating: "ữ", count: 50), maxBytes: 20)   // 3 bytes each
    #expect(cut.utf8.count <= 20 && cut.hasSuffix("…") && cut.hasPrefix("ữữữữữ"))
    #expect(Utf8.fit("🇻🇳🇻🇳🇻🇳", maxBytes: 12) == "🇻🇳…")           // never splits a flag
    #expect(Utf8.fit("abcdef", maxBytes: 2) == "")
}

@Test func shareGivesShortItemsTheirLengthAndSplitsTheRest() {
    let out = Utf8.share(["ab", String(repeating: "x", count: 100), String(repeating: "y", count: 100)], totalBytes: 42)
    #expect(out[0] == "ab")
    #expect(out[1].utf8.count == 20 && out[2].utf8.count == 20)
    #expect(out.map { $0.utf8.count }.reduce(0, +) <= 42)
    #expect(Utf8.share(["a", "b"], totalBytes: 0) == ["", ""])
}

@Test func oneLineTurnsControlCharactersIntoSpaces() {
    #expect(Utf8.oneLine("a\nb\tc\r\nd\u{2028}e") == "a b c  d e")
    #expect(Utf8.oneLine("👨‍👩‍👧 ok") == "👨‍👩‍👧 ok")   // ZWJ sequences untouched
}

// MARK: AskQuestion

private let twoQuestions: [String: JSONValue] = [
    "questions": .array([
        .object(["question": .string("Which color?"), "header": .string("Color"), "multiSelect": .bool(false),
                 "options": .array([.object(["label": .string("Red"), "description": .string("Warm")]),
                                    .object(["label": .string("Green")])])]),
        .object(["question": .string("Which fruits?"), "header": .string("Fruits"), "multiSelect": .bool(true),
                 "options": .array([.object(["label": .string("Apple"), "description": .string("a")]),
                                    .object(["label": .string("Banana"), "description": .string("b")]),
                                    .object(["label": .string("Cherry"), "description": .string("c")])])]),
    ]),
]

@Test func parsesAskUserQuestionInput() throws {
    let qs = try #require(AskQuestion.parse(twoQuestions))
    #expect(qs.count == 2)
    #expect(qs[0] == AskQuestion(question: "Which color?", header: "Color",
                                 options: [AskOption(label: "Red", description: "Warm"), AskOption(label: "Green", description: "")],
                                 multiSelect: false))
    #expect(qs[1].multiSelect && qs[1].options.map(\.label) == ["Apple", "Banana", "Cherry"])
}

@Test func parseRejectsShapesTheBoardCannotShow() {
    func q(_ text: String, _ n: Int, label: String = "L") -> JSONValue {
        .object(["question": .string(text), "options": .array((0..<n).map { _ in .object(["label": .string(label)]) })])
    }
    #expect(AskQuestion.parse([:]) == nil)
    #expect(AskQuestion.parse(["questions": .array([])]) == nil)
    #expect(AskQuestion.parse(["questions": .array((1...5).map { q("Q\($0)?", 2) })]) == nil)   // > 4 questions
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 5)])]) == nil)                        // > 4 options
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 0)])]) == nil)                        // no options
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 2, label: "  ")])]) == nil)          // empty label
    #expect(AskQuestion.parse(["questions": .array([q("Same?", 2), q("Same?", 2)])]) == nil)     // answers keyed by text
}

// MARK: Encoding

@Test func encodesQuestionPage() throws {
    let q = AskQuestion(question: "Which color?", header: "Color",
                        options: [AskOption(label: "Red", description: "Warm"), AskOption(label: "Green", description: ""),
                                  AskOption(label: "Blue", description: "Cool")], multiSelect: false)
    let d = BoardMessage.question(id: 0x01020304, index: 0, count: 2, project: "proj", question: q).encode()
    #expect(Array(d) == [7, 0x04, 0x03, 0x02, 0x01] + Array("0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue\nCool".utf8))
}

@Test func questionTextStaysWithinBoardLimit() {
    let long = String(repeating: "Mô tả rất dài bằng tiếng Việt 🚀 ", count: 20)
    let q = AskQuestion(question: String(repeating: "Câu hỏi dài? ", count: 30),
                        header: String(repeating: "Tiêu đề ", count: 10),
                        options: (1...4).map { AskOption(label: String(repeating: "Lựa chọn \($0) ", count: 10), description: long) },
                        multiSelect: true)
    let d = BoardMessage.question(id: 9, index: 3, count: 4, project: String(repeating: "dự-án-", count: 20), question: q).encode()
    #expect(d.count <= 5 + BoardMessage.textMax)
    let fields = String(data: d.dropFirst(5), encoding: .utf8)!.components(separatedBy: "\n")
    #expect(fields.count == 4 + 2 * 4)
    #expect(fields[0] == "3 4 1 4")
    #expect(fields[1].utf8.count <= 32 && fields[2].utf8.count <= 24)
    #expect(fields[3].utf8.count <= 120 && fields[3].hasSuffix("…"))
    #expect(fields[4].utf8.count <= 32 && fields[4].hasPrefix("Lựa chọn 1"))
    #expect(fields[5].hasPrefix("Mô tả"))     // descriptions keep a share of what is left
}

@Test func newlinesInFieldsBecomeSpaces() {
    let q = AskQuestion(question: "Line1\nLine2", header: "H\tX",
                        options: [AskOption(label: "A\nB", description: "d1\nd2")], multiSelect: false)
    #expect(text(.question(id: 1, index: 0, count: 1, project: "p\nq", question: q))
            == "0 1 0 1\np q\nH X\nLine1 Line2\nA B\nd1 d2")
}

@Test func encodesSessionRowAndRemoveAndClear() {
    let r = SessionRow(handle: 5, state: .working, since: 1_759_555_200, updated: 1_759_555_260,
                       focused: true, unseen: false, project: "dự-án", lastLine: "Done.")
    #expect(Array(BoardMessage.session(r).encode()) == [4, 5, 0, 0, 0] + Array("w 1759555200 1759555260 1\ndự-án\nDone.".utf8))
    var u = r
    u.focused = false; u.unseen = true; u.state = .needsYou
    #expect(text(.session(u)) == "n 1759555200 1759555260 2\ndự-án\nDone.")
    #expect(Array(BoardMessage.sessionRemove(handle: 5).encode()) == [5, 5, 0, 0, 0])
    #expect(Array(BoardMessage.sessionsClear.encode()) == [6, 0, 0, 0, 0])
}

@Test func sessionLineIsCutToFit() {
    let r = SessionRow(handle: 1, state: .idle, since: 1, updated: 2, focused: false, unseen: false,
                       project: "p", lastLine: String(repeating: "Xong rồi! ", count: 80))
    let d = BoardMessage.session(r).encode()
    #expect(d.count <= 5 + BoardMessage.textMax)
    #expect(String(data: d.dropFirst(5), encoding: .utf8)!.hasSuffix("…"))
}

@Test func permissionCarriesTheRuleLineAndKeepsItWhenTheSummaryIsCut() {
    #expect(text(.permission(id: 1, project: "p", tool: "Bash", summary: "npm test", alwaysRule: "Bash(npm test:*)"))
            == "p\nBash\nnpm test\nBash(npm test:*)")
    #expect(text(.permission(id: 1, project: "p", tool: "Bash", summary: "npm test")) == "p\nBash\nnpm test")
    let long = text(.permission(id: 1, project: "p", tool: "Bash", summary: String(repeating: "đường dẫn ", count: 60),
                                alwaysRule: "Bash(npm test:*)"))
    #expect(long.utf8.count <= BoardMessage.textMax)
    #expect(long.hasSuffix("…\nBash(npm test:*)"))
}

// MARK: Board → Mac

@Test func decodesBoardInputs() {
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 1])) == .choice(id: 0x01020304, .allow))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 2])) == .choice(id: 0x01020304, .deny))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 3])) == .choice(id: 0x01020304, .alwaysAllow))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 0x10, 2, 0x02, 0x05])) == .answers(id: 0x01020304, masks: [0x02, 0x05]))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x20, 2])) == .mode(.picker))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x20, 0])) == .mode(.other))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x21, 7, 0, 0, 0])) == .focus(handle: 7))
}

@Test func rejectsMalformedBoardInputs() {
    let bad: [[UInt8]] = [
        [1, 2, 3],                               // short
        [0, 0, 0, 0, 1],                         // decision for id 0
        [1, 0, 0, 0, 9],                         // unknown code
        [1, 0, 0, 0, 1, 0],                      // decision with a trailing byte
        [1, 0, 0, 0, 0x10, 0],                   // zero questions
        [1, 0, 0, 0, 0x10, 5, 1, 1, 1, 1, 1],    // five questions
        [1, 0, 0, 0, 0x10, 2, 1],                // count says 2, one mask
        [0, 0, 0, 0, 0x20, 3],                   // unknown mode
        [0, 0, 0, 0, 0x21, 0, 0, 0, 0],          // focus handle 0
        [1, 0, 0, 0, 0x20, 1],                   // mode with a request id
    ]
    for b in bad { #expect(BoardInput.decode(Data(b)) == nil, "\(b)") }
}
