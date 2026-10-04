import Foundation
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
    func close() { lock.withLock { _closed = true } }

    func hookGoesAway() { for h in lock.withLock({ handlers }) { h() } }
    var replies: [BridgeReply] { lock.withLock { _replies } }
    var closed: Bool { lock.withLock { _closed } }
}

private func event(_ name: String, extra: String = "") -> Data {
    Data(#"{"hook_event_name":"\#(name)","session_id":"s","cwd":"/Users/me/dự-án"\#(extra)}"#.utf8)
}

private let permissionLine = event("PermissionRequest", extra: #","tool_name":"Bash","tool_input":{"command":"npm test"}"#)

private func makeProcessor(ready: Bool, timeout: Duration = .seconds(90)) -> (HookProcessor, FakeBoard) {
    let board = FakeBoard(ready: ready)
    let requests = RequestQueue(send: { board.send($0) }, timeout: timeout)
    return (HookProcessor(board: board, requests: requests), board)
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

@Test(arguments: [Decision.allow, Decision.deny])
func permissionRoundTrip(_ decision: Decision) async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent == [.permission(id: board.permissionIds[0], project: "dự-án", tool: "Bash", summary: "npm test")])
    #expect(conn.replies.isEmpty)
    await p.requests.handle(Answer(id: board.permissionIds[0], decision: decision))
    await done.value
    #expect(conn.replies == [BridgeReply(decision: decision == .allow ? "allow" : "deny")])
}

@Test func hookDisconnectCancelsBoardRequest() async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let id = board.permissionIds[0]
    conn.hookGoesAway()
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.last == .cancel(id: id))
    #expect(conn.replies == [BridgeReply(decision: nil)])   // never a decision
    // A late tap for the cancelled request is ignored
    await p.requests.handle(Answer(id: id, decision: .allow))
    #expect(conn.replies.count == 1)
}

@Test func stopAndNotificationSendFinishedOnlyWhenReady() async {
    for name in ["Stop", "Notification"] {
        let line = name == "Stop"
            ? Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/proj","last_assistant_message":"Xong rồi 🎉"}"#.utf8)
            : event(name, extra: #","notification_type":"idle_prompt""#)
        let (ready, readyBoard) = makeProcessor(ready: true)
        let c1 = FakeConn()
        await ready.process(line, c1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(readyBoard.sent.count == 1)
        if case .finished(_, let project, let text) = readyBoard.sent.first {
            #expect(project == (name == "Stop" ? "proj" : "dự-án"))
            #expect(text == (name == "Stop" ? "Xong rồi 🎉" : "Claude is waiting for you"))
        } else {
            Issue.record("expected a finished message for \(name)")
        }
        #expect(c1.replies.isEmpty && c1.closed)

        let (notReady, idleBoard) = makeProcessor(ready: false)
        let c2 = FakeConn()
        await notReady.process(line, c2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(idleBoard.sent.isEmpty)
        #expect(c2.replies.isEmpty && c2.closed)
    }
}

@Test func garbageLineClosesWithoutReply() async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    await p.process(Data("not json".utf8), conn)
    #expect(conn.replies.isEmpty && conn.closed && board.sent.isEmpty)
}
