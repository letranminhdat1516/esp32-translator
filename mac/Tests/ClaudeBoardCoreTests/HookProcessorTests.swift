import Foundation
import os
import Testing
@testable import ClaudeBoardCore

/// Fake BLE link: records what would be written to the board.
final class FakeBoard: BoardLinking, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private var _sent: [BoardMessage] = []

    init(ready: Bool) { self.ready = ready }

    var isReady: Bool { lock.withLock { ready } }
    func send(_ message: BoardMessage) { lock.withLock { _sent.append(message) } }
    var sent: [BoardMessage] { lock.withLock { _sent } }
    var permissionIds: [UInt32] { sent.compactMap { if case .permission(let id, _, _, _, _) = $0 { id } else { nil } } }
}

/// Fake hook connection: records the reply and lets the test simulate the hook going away.
final class FakeConn: HookConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []
    private var _replies: [BridgeReply] = []
    private var _closed = false

    func onPeerGone(_ handler: @escaping @Sendable () -> Void) { lock.withLock { handlers.append(handler) } }
    func reply(_ reply: BridgeReply) { lock.withLock { _replies.append(reply); _closed = true } }
    func close() {
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in _closed = true; return _closeObserver }
        observer?()
    }
    /// Runs when `close()` is called (to see what had happened by then)
    var closeObserver: (@Sendable () -> Void)? {
        get { lock.withLock { _closeObserver } }
        set { lock.withLock { _closeObserver = newValue } }
    }
    private var _closeObserver: (@Sendable () -> Void)?

    func hookGoesAway() { for h in lock.withLock({ handlers }) { h() } }
    var replies: [BridgeReply] { lock.withLock { _replies } }
    var closed: Bool { lock.withLock { _closed } }
}

private func event(_ name: String, extra: String = "") -> Data {
    Data(#"{"hook_event_name":"\#(name)","session_id":"s","cwd":"/Users/me/dự-án"\#(extra)}"#.utf8)
}

private extension Data {
    /// The same event line for another session id
    func replacingSession(_ id: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""session_id":"s""#, with: #""session_id":"\#(id)""#).utf8)
    }
}

private let permissionLine = event("PermissionRequest", extra: #","tool_name":"Bash","tool_input":{"command":"npm test"}"#)

private func makeProcessor(ready: Bool, timeout: Duration = .seconds(90)) -> (HookProcessor, FakeBoard) {
    let board = FakeBoard(ready: ready)
    let requests = RequestQueue(send: { board.send($0) }, timeout: timeout)
    let hub = SessionHub(sessionHooks: true, post: { await requests.post($0) },
                         finished: { await requests.notifyFinished(project: $0, line: $1) })
    return (HookProcessor(board: board, requests: requests, hub: hub), board)
}

@Test func boardNotReadyRepliesNullImmediately() async {
    let (p, board) = makeProcessor(ready: false)
    let conn = FakeConn()
    let start = ContinuousClock.now
    await p.process(permissionLine, conn)
    #expect(ContinuousClock.now - start < .milliseconds(200))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    try? await Task.sleep(for: .milliseconds(30))
    #expect(board.sent.isEmpty)
}

@Test(arguments: [BoardChoice.allow, BoardChoice.deny])
func permissionRoundTrip(_ choice: BoardChoice) async throws {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    let id = try await shownPermission(board)
    #expect(board.sent == [.permission(id: id, project: "dự-án", tool: "Bash", summary: "npm test")])
    #expect(conn.replies.isEmpty)
    await p.requests.handle(.choice(id: id, choice))
    await done.value
    #expect(conn.replies == [BridgeReply(decision: choice == .allow ? "allow" : "deny")])
}

@Test func hookDisconnectCancelsBoardRequest() async throws {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    let id = try await shownPermission(board)
    conn.hookGoesAway()
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.last == .cancel(id: id))
    #expect(conn.replies == [BridgeReply(decision: nil)])   // never a decision
    // A late tap for the cancelled request is ignored
    await p.requests.handle(.choice(id: id, .allow))
    #expect(conn.replies.count == 1)
}

@Test func stopOfTheFocusedSessionSendsFinishedAndIdleNotificationDoesNot() async {
    let (p, board) = makeProcessor(ready: true)
    let stop = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/proj","last_assistant_message":"Xong rồi 🎉"}"#.utf8)
    let c1 = FakeConn()
    await p.process(stop, c1)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.count == 1)
    if case .finished(_, let project, let text) = board.sent.first {
        #expect(project == "proj" && text == "Xong rồi 🎉")
    } else {
        Issue.record("expected a finished message")
    }
    #expect(c1.replies.isEmpty && c1.closed)

    let c2 = FakeConn()
    await p.process(event("Notification", extra: #","notification_type":"idle_prompt""#), c2)
    await p.process(event("Stop", extra: #","last_assistant_message":"other session""#).replacingSession("t"), FakeConn())
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.count == 1)                 // idle_prompt and a non-focused Stop are silent
    #expect(c2.replies.isEmpty && c2.closed)
}

@Test func answeredRequestSetsTheSessionWorking() async throws {
    let (p, board) = makeProcessor(ready: true)
    await p.process(event("UserPromptSubmit"), FakeConn())
    await p.hub?.boardInput(.mode(.claude))
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    let id = try await shownPermission(board)
    #expect(board.sent.contains { if case .session(let r) = $0 { r.state == .needsYou } else { false } })
    await p.requests.handle(.choice(id: id, .allow))
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    if case .session(let r) = board.sent.last { #expect(r.state == .working) } else { Issue.record("expected a row") }
}

@Test func requestAnsweredInTheTerminalSetsTheSessionWorking() async throws {
    let (p, board) = makeProcessor(ready: true)
    await p.process(event("UserPromptSubmit"), FakeConn())
    await p.hub?.boardInput(.mode(.claude))
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    let id = try await shownPermission(board)
    conn.hookGoesAway()                         // answered in the terminal: the hook went away
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.contains(.cancel(id: id)))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    if case .session(let r) = board.sent.last { #expect(r.state == .working) } else { Issue.record("expected a row") }
}

@Test func requestTimeoutLeavesTheSessionNeedingYou() async {
    let (p, board) = makeProcessor(ready: true, timeout: .milliseconds(50))
    await p.process(event("UserPromptSubmit"), FakeConn())
    await p.hub?.boardInput(.mode(.claude))
    let conn = FakeConn()
    await p.process(permissionLine, conn)       // nobody taps: falls through to the terminal prompt
    try? await Task.sleep(for: .milliseconds(50))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    let lastRow = board.sent.last { if case .session = $0 { true } else { false } }
    if case .session(let r) = lastRow { #expect(r.state == .needsYou) } else { Issue.record("expected a row") }
}

@Test func garbageLineClosesWithoutReply() async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    await p.process(Data("not json".utf8), conn)
    #expect(conn.replies.isEmpty && conn.closed && board.sent.isEmpty)
}
private let questionLine = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"Warm"},{"label":"Green","description":""}],"multiSelect":false},{"question":"Which fruits?","header":"Fruits","options":[{"label":"Apple","description":"a"},{"label":"Banana","description":"b"},{"label":"Cherry","description":"c"}],"multiSelect":true}]}}"#.utf8)

/// Polls (at most 2 s) until `value` is non-nil: never a fixed sleep followed by indexing
func eventually<T>(_ value: () -> T?, sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
    let end = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < end {
        if let v = value() { return v }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return try #require(value(), sourceLocation: sourceLocation)
}

/// Polls (at most 2 s) until `condition` holds; false if it never did
func within(_ condition: () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// The id of the permission request the board shows (waits for it)
private func shownPermission(_ board: FakeBoard) async throws -> UInt32 {
    try await eventually { board.permissionIds.first }
}

/// The id of the question the board shows (waits for its first page)
private func shownQuestion(_ board: FakeBoard) async throws -> UInt32 {
    try await eventually { pages(board).first?.id }
}

private func pages(_ board: FakeBoard) -> [(id: UInt32, index: Int, count: Int)] {
    board.sent.compactMap { m -> (id: UInt32, index: Int, count: Int)? in
        if case .question(let id, let index, let count, _, _) = m { return (id, index, count) }
        return nil
    }
}

@Test func questionRoundTripRepliesWithTheMappedAnswers() async throws {
    if HookSchema.questionAnswers == .terminalOnly { return }      // questions never reach the board then
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let shown = pages(board)
    #expect(shown.map(\.index) == [0, 1] && shown.allSatisfy { $0.count == 2 && $0.id == shown[0].id })
    await p.requests.handle(.answers(id: shown[0].id, masks: [0b10, 0b101]))
    await done.value
    let e = try HookEvent.parse(questionLine)
    let expected = AnswerMapping.questionReply([0b10, 0b101], questions: try #require(AskQuestion.parse(e.toolInput)),
                                               toolInput: e.toolInput)
    #expect(conn.replies == [expected])
}

@Test func hookDisconnectCancelsQuestion() async throws {
    if HookSchema.questionAnswers == .terminalOnly { return }
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    let id = try await shownQuestion(board)
    conn.hookGoesAway()                         // answered in the terminal / Remote Control
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.last == .cancel(id: id))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    await p.requests.handle(.answers(id: id, masks: [1, 1]))   // a late Send changes nothing
    #expect(conn.replies.count == 1)
}

@Test func unsupportedQuestionFallsThroughImmediately() async {
    let line = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"},{"label":"5"}]}]}}"#.utf8)
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let start = ContinuousClock.now
    await p.process(line, conn)
    #expect(ContinuousClock.now - start < .milliseconds(200))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    try? await Task.sleep(for: .milliseconds(30))
    #expect(board.sent.isEmpty)
}

@Test func permissionOffersAlwaysAllowOnlyWithAUsableSuggestion() async throws {
    let line = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"git push"},"permission_suggestions":[{"rule":"Bash(git push *)","description":"d","specificity":"moderate"}]}"#.utf8)
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(line, conn) }
    let id = try await shownPermission(board)
    let rule = AnswerMapping.alwaysRule(suggestions: try? HookEvent.parse(line).permissionSuggestions)
    #expect(board.sent == [.permission(id: id, project: "proj", tool: "Bash", summary: "git push", alwaysRule: rule)])
    let choice: BoardChoice = rule == nil ? .allow : .alwaysAllow
    await p.requests.handle(.choice(id: id, choice))
    await done.value
    let expected = AnswerMapping.permissionReply(rule == nil ? .allow : .alwaysAllow,
                                                 suggestions: try? HookEvent.parse(line).permissionSuggestions)
    #expect(conn.replies == [expected])
}

@Test func alwaysAllowTapSendsTheAddRulesSuggestionVerbatim() async throws {
    let line = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}"#.utf8)
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(line, conn) }
    let id = try await shownPermission(board)
    #expect(board.sent == [.permission(id: id, project: "proj", tool: "Bash", summary: "npm test",
                                       alwaysRule: HookSchema.alwaysAllow == .unsupported ? nil : "Bash(npm test:*)")])
    await p.requests.handle(.choice(id: id, .alwaysAllow))
    await done.value
    let suggestions = try HookEvent.parse(line).permissionSuggestions
    #expect(conn.replies == [AnswerMapping.permissionReply(.alwaysAllow, suggestions: suggestions)])
    if HookSchema.alwaysAllow == .suggestionsVerbatim {
        #expect(conn.replies[0].updatedPermissions == suggestions.map { .array([$0.array![0]]) })
    }
}

@Test func denyWithReasonReachesTheHook() async throws {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    let id = try await shownPermission(board)
    #expect(await p.requests.denyWithReason(id: id, message: "chạy pnpm test thay vì npm test"))
    await done.value
    #expect(conn.replies == [BridgeReply(decision: "deny",
                                         message: "The user denied this on the board and said: chạy pnpm test thay vì npm test")])
}

@Test func questionWithOtherRepliesWithTheSpokenText() async throws {
    if HookSchema.questionAnswers == .terminalOnly { return }
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    let id = try await shownQuestion(board)
    #expect(await p.requests.setOther(id: id, question: 0, text: "Tím"))
    await p.requests.handle(.answers(id: id, masks: [0x80, 0b101]))
    await done.value
    let e = try HookEvent.parse(questionLine)
    let expected = AnswerMapping.questionReply([0x80, 0b101], others: [0: "Tím"],
                                               questions: try #require(AskQuestion.parse(e.toolInput)), toolInput: e.toolInput)
    #expect(conn.replies == [expected])
}

@Test func fireAndForgetEventsReleaseTheHookBeforeTheSessionUpdate() async throws {
    // The hook waits for the close (at most 1 s): it must not also wait for the session bookkeeping
    let order = OSAllocatedUnfairLock<[String]>(initialState: [])
    let board = FakeBoard(ready: true)
    let requests = RequestQueue(send: { board.send($0) })
    let hub = SessionHub(sessionHooks: true, post: { _ in order.withLock { $0.append("post") } },
                         finished: { _, _ in order.withLock { $0.append("finished") } })
    let p = HookProcessor(board: board, requests: requests, hub: hub)
    await hub.boardInput(.mode(.claude))
    for name in ["UserPromptSubmit", "Notification", "Stop"] {
        order.withLock { $0 = [] }
        let conn = FakeConn()
        conn.closeObserver = { order.withLock { $0.append("close") } }
        await p.process(event(name), conn)
        #expect(conn.closed && conn.replies.isEmpty)
        let seen = order.withLock { $0 }
        #expect(seen.first == "close", "\(name): \(seen)")
        if name == "UserPromptSubmit" { #expect(seen.contains("post")) }   // the new row is still sent
    }
}

@Test func hookFeedHandlesLinesInArrivalOrder() async throws {
    // The first line's session update is slow: the lines behind it must still be recorded after it
    let order = OSAllocatedUnfairLock<[Int]>(initialState: [])
    let feed = HookFeed(accept: { line, _ in
        let n = Int(String(decoding: line, as: UTF8.self))!
        if n == 0 { try? await Task.sleep(for: .milliseconds(80)) }
        order.withLock { $0.append(n) }
        return nil
    })
    for n in 0..<20 { feed.submit(Data("\(n)".utf8), FakeConn()) }
    for _ in 0..<100 where order.withLock({ $0.count }) < 20 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(order.withLock { $0 } == Array(0..<20))
}

@Test func hookFeedRecordsStateInOrderWithoutWaitingForARequest() async throws {
    // A request waiting for the board does not hold up the events behind it, and the session's state is the
    // one of the last line received (Stop after the prompt: idle, the focused session's "done")
    let board = FakeBoard(ready: true)
    let requests = RequestQueue(send: { board.send($0) })
    let finished = OSAllocatedUnfairLock<[String]>(initialState: [])
    let hub = SessionHub(sessionHooks: true, post: { await requests.post($0) },
                         finished: { p, _ in finished.withLock { $0.append(p) } })
    let feed = HookFeed(HookProcessor(board: board, requests: requests, hub: hub))
    await hub.boardInput(.mode(.claude))
    let request = FakeConn()
    feed.submit(permissionLine.replacingSession("other"), request)
    var conns: [FakeConn] = []
    for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
        let c = FakeConn()
        conns.append(c)
        feed.submit(event(name), c)
    }
    for _ in 0..<100 where !(conns.allSatisfy(\.closed) && !board.permissionIds.isEmpty) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(conns.allSatisfy { $0.closed && $0.replies.isEmpty })
    #expect(board.permissionIds.count == 1 && request.replies.isEmpty)   // still waiting for the board
    #expect(await hub.focusedSessionId == "other")                        // the first line recorded first
    request.hookGoesAway()
    for _ in 0..<100 where request.replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(request.replies == [BridgeReply(decision: nil)])
}
