import Foundation
import Testing
@testable import ClaudeBoardCore

actor Sent {
    var messages: [BoardMessage] = []
    func add(_ m: BoardMessage) { messages.append(m) }
    func permissionIds() -> [UInt32] { messages.compactMap { if case .permission(let id, _, _, _) = $0 { id } else { nil } } }
}

@Test func answersTheWaitingHook() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.permissionIds()[0]
    await q.handle(Answer(id: id, decision: .allow))
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
    await q.handle(Answer(id: first, decision: .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    await q.handle(Answer(id: ids[1], decision: .allow))
    #expect(await a == .deny)
    #expect(await b == .allow)
}

@Test func ignoresAnswerForUnknownId() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(200))
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.handle(Answer(id: 999_999, decision: .allow))
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

private func tag(_ m: BoardMessage) -> String {
    switch m {
    case .permission(let id, _, _, _): "perm\(id)"
    case .cancel(let id): "cancel\(id)"
    case .finished(let id, _, _): "fin\(id)"
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
    await q.handle(Answer(id: ids[1], decision: .allow))
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
