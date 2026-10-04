import Foundation
import Testing
@testable import ClaudeBoardCore

final class FakeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64
    init(_ t: Int64) { self.t = t }
    var now: Int64 { lock.withLock { t } }
    func advance(_ s: Int64) { lock.withLock { t += s } }
}

private func makeHub() -> (SessionHub, Sent, FakeNow) {
    let sent = Sent()
    let now = FakeNow(1_000)
    let hub = SessionHub(sessionHooks: true,
                         post: { await sent.add($0) },
                         finished: { await sent.add(.finished(id: 0, project: $0, line: $1)) },
                         clock: { now.now })
    return (hub, sent, now)
}

private func kinds(_ ms: some Collection<BoardMessage>) -> [String] {
    ms.map {
        switch $0 {
        case .session(let r): "row\(r.handle)"
        case .sessionRemove(let h): "rm\(h)"
        case .sessionsClear: "clear"
        case .finished(_, let p, let l): "fin:\(p):\(l)"
        default: "other"
        }
    }
}

private func rows(_ ms: some Collection<BoardMessage>) -> [SessionRow] {
    ms.compactMap { if case .session(let r) = $0 { r } else { nil } }
}

@Test func inactiveBoardGetsNoSessionTraffic() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit"))
    await hub.record(hookEvent("UserPromptSubmit", sid: "s2"))
    await hub.boardInput(.mode(.other))
    #expect(await sent.messages.isEmpty)
}

@Test func activationSendsClearThenAllRows() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.record(hookEvent("SessionStart", sid: "b", cwd: "/x/beta"))
    await hub.boardInput(.mode(.claude))
    let k = kinds(await sent.messages)
    #expect(k.first == "clear" && k.count == 3 && Set(k.dropFirst()) == ["row1", "row2"])
}

@Test func deltasCarryOnlyChangedRows() async {
    let (hub, sent, now) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.record(hookEvent("SessionStart", sid: "b"))
    await hub.boardInput(.mode(.picker))
    let before = await sent.messages.count
    now.advance(5)
    await hub.record(hookEvent("UserPromptSubmit", sid: "b"))
    let new = await sent.messages.dropFirst(before)
    #expect(kinds(new) == ["row2"])
    #expect(rows(new).first?.state == .working && rows(new).first?.since == 1_005)
}

@Test func leavingThePickerMarksDoneSessionsSeen() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))           // focused
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta"))       // done while not focused
    await hub.boardInput(.mode(.picker))
    #expect(rows(await sent.messages).first { $0.handle == 2 }?.unseen == true)   // the picker shows "new"
    let before = await sent.messages.count
    await hub.boardInput(.mode(.claude))           // picker → Claude: still active, so a delta, not a resync
    let after = await sent.messages.dropFirst(before)
    #expect(kinds(after) == ["row2"])
    #expect(rows(after).first?.unseen == false)
}

@Test func focusFromTheBoardMovesFocusAndClearsUnseen() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta"))
    await hub.boardInput(.mode(.picker))
    let before = await sent.messages.count
    await hub.boardInput(.focus(handle: 2))
    let changed = rows(await sent.messages.dropFirst(before))
    #expect(Set(changed.map(\.handle)) == [1, 2])
    #expect(changed.first { $0.handle == 2 }?.focused == true && changed.first { $0.handle == 2 }?.unseen == false)
    #expect(changed.first { $0.handle == 1 }?.focused == false)
    #expect(await hub.focusedSessionId == "b")
}

@Test func focusedStopSendsFinishedEvenWhenInactive() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a", cwd: "/x/alpha"))
    await hub.record(hookEvent("Stop", sid: "a", cwd: "/x/alpha", extra: #","last_assistant_message":"Done.""#))
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta", extra: #","last_assistant_message":"Other.""#))
    #expect(kinds(await sent.messages) == ["fin:alpha:Done."])
}

@Test func reconnectWhileActiveResyncs() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    let before = await sent.messages.count
    await hub.boardConnected(true)
    #expect(kinds(await sent.messages.dropFirst(before)) == ["clear", "row1"])
}

@Test func disconnectStopsTraffic() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    await hub.boardConnected(false)
    let before = await sent.messages.count
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))
    #expect(await sent.messages.count == before)
    await hub.boardConnected(true)                   // the board reports its mode again after reconnecting
    #expect(await sent.messages.count == before)
    await hub.boardInput(.mode(.picker))
    #expect(kinds(await sent.messages.dropFirst(before)) == ["clear", "row1"])
}

@Test func tickDropsEndedSessionsFromTheBoard() async {
    let (hub, sent, now) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    await hub.record(hookEvent("SessionEnd", sid: "a"))
    let before = await sent.messages.count
    now.advance(600)
    await hub.tick()
    #expect(kinds(await sent.messages.dropFirst(before)) == ["rm1"])
}

@Test func diffRemovesFirstThenUpsertsInOrder() {
    func row(_ h: UInt32, _ updated: Int64) -> SessionRow {
        SessionRow(handle: h, state: .idle, since: 0, updated: updated, focused: false, unseen: false, project: "p", lastLine: "")
    }
    let old: [UInt32: SessionRow] = [1: row(1, 10), 2: row(2, 20), 3: row(3, 30)]
    let new = [row(4, 40), row(3, 30), row(2, 25)]
    #expect(kinds(SessionSync.diff(old: old, new: new)) == ["rm1", "row4", "row2"])
}

@Test func aSlowHandOffNeverLeavesAStaleRowOnTheBoard() async {
    let sent = Sent()
    let hub = SessionHub(sessionHooks: true,
                         post: { m in                      // the "working" row is slow to hand over
                             if case .session(let r) = m, r.state == .working { try? await Task.sleep(for: .milliseconds(40)) }
                             await sent.add(m)
                         },
                         finished: { await sent.add(.finished(id: 0, project: $0, line: $1)) })
    await hub.boardInput(.mode(.claude))
    async let first: Void = hub.record(hookEvent("UserPromptSubmit"))
    try? await Task.sleep(for: .milliseconds(10))
    await hub.record(hookEvent("Stop", extra: #","last_assistant_message":"Done.""#))
    await first
    try? await Task.sleep(for: .milliseconds(60))
    let messages = await sent.messages
    var last: [UInt32: SessionRow] = [:]
    for m in messages { if case .session(let r) = m { last[r.handle] = r } }
    #expect(last.values.sorted { $0.handle < $1.handle } == (await hub.currentRows))
    #expect(kinds(messages) == ["clear", "row1", "fin:alpha:Done.", "row1"])   // in event order
}

@Test func concurrentEventsNeverLeaveAStaleRowOnTheBoard() async {
    let sent = Sent()
    let hub = SessionHub(sessionHooks: true,
                         post: { m in for _ in 0..<Int.random(in: 0...3) { await Task.yield() }; await sent.add(m) },
                         finished: { _, _ in })
    await hub.boardInput(.mode(.claude))
    await withTaskGroup(of: Void.self) { g in
        for i in 0..<40 {
            g.addTask { await hub.record(hookEvent(i % 2 == 0 ? "UserPromptSubmit" : "Stop", sid: "s\(i % 3)")) }
        }
    }
    try? await Task.sleep(for: .milliseconds(20))
    var last: [UInt32: SessionRow] = [:]
    for m in await sent.messages { if case .session(let r) = m { last[r.handle] = r } }
    #expect(last.values.sorted { $0.handle < $1.handle } == (await hub.currentRows).sorted { $0.handle < $1.handle })
}
