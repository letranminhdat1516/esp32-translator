import Foundation
import Testing
@testable import ClaudeBoardCore

actor Sent {
    var messages: [BoardMessage] = []
    func add(_ m: BoardMessage) { messages.append(m) }
    func permissionIds() -> [UInt32] { messages.compactMap { if case .permission(let id, _, _, _, _) = $0 { id } else { nil } } }
    func questionIds() -> [UInt32] { messages.compactMap { if case .question(let id, _, _, _, _) = $0 { id } else { nil } } }
}

private let color = AskQuestion(question: "Which color?", header: "Color",
                                options: [AskOption(label: "Red", description: ""), AskOption(label: "Green", description: "")],
                                multiSelect: false)
private let fruits = AskQuestion(question: "Which fruits?", header: "Fruits",
                                 options: ["Apple", "Banana", "Cherry"].map { AskOption(label: $0, description: "") },
                                 multiSelect: true)
private let questionShape = RequestShape.question(options: [2, 3], multi: [false, true])

private func askQuestions(_ q: RequestQueue) async -> BoardResponse? {
    await q.ask(shape: questionShape) { id in
        [.question(id: id, index: 0, count: 2, project: "p", question: color),
         .question(id: id, index: 1, count: 2, project: "p", question: fruits)]
    }
}

@Test func answersTheWaitingHook() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.permissionIds()[0]
    await q.handle(.choice(id: id, .allow))
    #expect(await d == .allow)
}

@Test func queuesSecondRequestUntilFirstAnswered() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = q.ask(project: "p", tool: "Bash", summary: "two")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.permissionIds().count == 1)
    let first = await sent.permissionIds()[0]
    await q.handle(.choice(id: first, .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    await q.handle(.choice(id: ids[1], .allow))
    #expect(await a == .deny)
    #expect(await b == .allow)
}

@Test func answerForQueuedRequestIsIgnored() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(300))
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(30))
    let first = await sent.permissionIds()[0]
    // The queued question's id is first + 1; it is not on the board yet, so its answer must not count
    await q.handle(.answers(id: first &+ 1, masks: [1, 1]))
    await q.handle(.choice(id: first, .allow))
    #expect(await a == .allow)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.questionIds() == [first &+ 1, first &+ 1])
    #expect(await b == nil)     // timed out: the early answer was not kept
}

@Test func questionRoundTripSendsEveryPageThenTakesTheMasks() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let ids = await sent.questionIds()
    #expect(ids.count == 2 && ids[0] == ids[1])
    await q.handle(.answers(id: ids[0], masks: [0b10, 0b101]))
    #expect(await r == .answers([0b10, 0b101]))
}

@Test func answersMustFitTheQuestionShape() {
    let bad: [[UInt8]] = [[0b10], [0b10, 0b101, 1], [0, 0b1], [0b11, 0b1], [0b100, 0b1], [0b1, 0b1000]]
    for m in bad { #expect(questionShape.accept(.answers(id: 1, masks: m)) == nil, "\(m)") }
    #expect(questionShape.accept(.answers(id: 1, masks: [0b01, 0b111])) == .answers([0b01, 0b111]))
    #expect(questionShape.accept(.choice(id: 1, .allow)) == nil)
    #expect(RequestShape.permission(alwaysOffered: false).accept(.answers(id: 1, masks: [1])) == nil)
}

@Test func alwaysAllowOnlyWhenOffered() {
    #expect(RequestShape.permission(alwaysOffered: false).accept(.choice(id: 1, .alwaysAllow)) == nil)
    #expect(RequestShape.permission(alwaysOffered: true).accept(.choice(id: 1, .alwaysAllow)) == .alwaysAllow)
    #expect(RequestShape.permission(alwaysOffered: false).accept(.choice(id: 1, .deny)) == .deny)
}

@Test func ignoresAnswerForUnknownId() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(200))
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.handle(.choice(id: 999_999, .allow))
    #expect(await d == nil)        // timed out, never approved by a stray answer
}

@Test func timeoutFallsThroughAndCancelsOnBoard() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(100))
    #expect(await q.ask(project: "p", tool: "Bash", summary: "ls") == nil)
    try? await Task.sleep(for: .milliseconds(30))
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func cancelsWhenHookDisconnects() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    let t = Task { await q.ask(project: "p", tool: "Bash", summary: "ls") }
    try? await Task.sleep(for: .milliseconds(30))
    t.cancel()
    #expect(await t.value == nil)
    try? await Task.sleep(for: .milliseconds(30))
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func boardDisconnectReleasesWaiters() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.boardDisconnected()
    #expect(await d == nil)
}

@Test func postGoesThroughTheSameFifo() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    await q.post(.sessionsClear)
    await q.post(.sessionRemove(handle: 3))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.messages == [.sessionsClear, .sessionRemove(handle: 3)])
}

private func tag(_ m: BoardMessage) -> String {
    switch m {
    case .permission(let id, _, _, _, _): "perm\(id)"
    case .cancel(let id): "cancel\(id)"
    case .finished(let id, _, _): "fin\(id)"
    case .time: "time"
    case .session(let r): "row\(r.handle)"
    case .sessionRemove(let h): "rm\(h)"
    case .sessionsClear: "clear"
    case .question(let id, let index, _, _, _): "q\(id).\(index)"
    case .voice(let id, _): "voice\(id)"
    }
}

@Test func cancelOfHeadIsSentBeforeNextPermission() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    let a = Task { await q.ask(project: "p", tool: "Bash", summary: "one") }
    try? await Task.sleep(for: .milliseconds(30))
    async let b = q.ask(project: "p", tool: "Bash", summary: "two")
    try? await Task.sleep(for: .milliseconds(30))
    a.cancel()
    try? await Task.sleep(for: .milliseconds(50))
    let msgs = await sent.messages
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    #expect(msgs.map(tag) == ["perm\(ids[0])", "cancel\(ids[0])", "perm\(ids[1])"])
    await q.handle(.choice(id: ids[1], .allow))
    #expect(await b == .allow)
}

@Test func idsNeverZeroAcrossWrap() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    await q.seedNextId(UInt32.max)
    await q.notifyFinished(project: "p", line: "a")   // uses max
    await q.notifyFinished(project: "p", line: "b")   // must skip 0
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.messages.map(tag)
    #expect(ids == ["fin\(UInt32.max)", "fin1"])
}

@Test func otherAnswerNeedsTheSpokenText() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.questionIds()[0]
    await q.handle(.answers(id: id, masks: [0x80, 0b001]))          // Other on page 1, but nothing spoken yet
    #expect(await q.shownShape(id: id) != nil)                     // still waiting
    #expect(await q.setOther(id: id, question: 0, text: "Tím"))
    #expect(await q.setOther(id: id, question: 0, text: "Tím than"))   // Say again replaces it
    await q.handle(.answers(id: id, masks: [0x80, 0b101]))
    #expect(await r == .answers([0x80, 0b101], others: [0: "Tím than"]))
}

@Test func otherTextIsOnlySentForTicked() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.questionIds()[0]
    #expect(await q.setOther(id: id, question: 1, text: "Durian"))
    await q.handle(.answers(id: id, masks: [0b10, 0b001]))          // spoken, then not ticked: not part of the answer
    #expect(await r == .answers([0b10, 0b001]))
}

@Test func otherCombinesOnlyOnMultiSelect() {
    let shape = RequestShape.question(options: [2, 3], multi: [false, true])
    #expect(shape.accept(.answers(id: 1, masks: [0x81, 0b1]), others: [0]) == nil)       // single: one choice only
    #expect(shape.accept(.answers(id: 1, masks: [0b1, 0x81]), others: [1]) == .answers([0b1, 0x81]))
    #expect(shape.accept(.answers(id: 1, masks: [0b1, 0x80]), others: []) == nil)        // no text for page 2
}

@Test func setOtherOnlyForTheShownQuestion() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let p = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let r = askQuestions(q)                                    // queued behind the permission
    try? await Task.sleep(for: .milliseconds(30))
    let permission = await sent.permissionIds()[0]
    #expect(await !q.setOther(id: permission, question: 0, text: "x"))   // not a question
    #expect(await !q.setOther(id: permission &+ 1, question: 0, text: "x"))   // not shown (queued or unknown)
    await q.handle(.choice(id: permission, .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let question = await sent.questionIds()[0]
    #expect(await !q.setOther(id: question, question: 2, text: "x"))     // only 2 questions
    #expect(await !q.setOther(id: question, question: 0, text: ""))      // nothing spoken
    #expect(await q.setOther(id: question, question: 1, text: "Durian"))
    await q.handle(.answers(id: question, masks: [0b1, 0x80]))
    #expect(await p == .deny)
    #expect(await r == .answers([0b1, 0x80], others: [1: "Durian"]))
}

@Test func denyWithReasonOnlyForTheShownPermission() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(30))
    let first = await sent.permissionIds()[0]
    #expect(await !q.denyWithReason(id: first &+ 999, message: "no"))
    #expect(await !q.denyWithReason(id: first, message: ""))
    let notice = BoardMessage.voice(id: 9, .done("Denied with your reason"))
    #expect(await q.denyWithReason(id: first, message: "dùng pnpm thay vì npm", notice: notice))
    #expect(await a == .denyWithReason("dùng pnpm thay vì npm"))
    try? await Task.sleep(for: .milliseconds(30))
    let question = await sent.questionIds()[0]
    #expect(await !q.denyWithReason(id: question, message: "no"))        // a question is not denied this way
    // The notice reaches the board before the next request, and no cancel is sent for an answered request
    let order = await sent.messages
    let noticeAt = order.firstIndex(of: notice)
    let nextAt = order.firstIndex { if case .question = $0 { true } else { false } }
    #expect(noticeAt != nil && nextAt != nil && noticeAt! < nextAt!)
    #expect(!order.contains(.cancel(id: first)))
    await q.handle(.answers(id: question, masks: [0b1, 0b1]))
    _ = await b
}

@Test func shownShapeIsOnlyTheHead() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(shape: .permission(alwaysOffered: true)) { id in
        [.permission(id: id, project: "p", tool: "Bash", summary: "x", alwaysRule: "Bash(x)")]
    }
    try? await Task.sleep(for: .milliseconds(30))
    let id = await sent.permissionIds()[0]
    #expect(await q.shownShape(id: id) == .permission(alwaysOffered: true))
    #expect(await q.shownShape(id: id &+ 1) == nil)
    await q.handle(.choice(id: id, .allow))
    #expect(await a == .allow)
    #expect(await q.shownShape(id: id) == nil)
}
