import Foundation

/// The BLE link to the board, as the daemon's request handling sees it.
public protocol BoardLinking: Sendable {
    /// Subscribed to the board's answer characteristic: messages can be delivered and answered.
    var isReady: Bool { get }
    func send(_ message: BoardMessage)
}

/// One accepted hook connection on the daemon's Unix socket.
public protocol HookConnection: Sendable {
    /// Calls `handler` (possibly more than once) when the hook side goes away: EOF, error, a stray byte,
    /// or the connection being cancelled. Harmless after the reply has been sent.
    func onPeerGone(_ handler: @escaping @Sendable () -> Void)
    /// Sends one reply line, then closes the connection.
    func reply(_ reply: BridgeReply)
    /// Closes without replying.
    func close()
}

/// Handles one hook event line received by the daemon. Never decides on its own: a request is answered
/// only with what the board sent back, and every failure path replies `null` or nothing.
public struct HookProcessor: Sendable {
    public let board: any BoardLinking
    public let requests: RequestQueue
    public let hub: SessionHub?
    private let log: @Sendable (String) -> Void

    public init(board: any BoardLinking, requests: RequestQueue, hub: SessionHub? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.board = board
        self.requests = requests
        self.hub = hub
        self.log = log
    }

    public func process(_ line: Data, _ conn: any HookConnection) async {
        guard let e = try? HookEvent.parse(line) else { conn.close(); return }
        await hub?.record(e)       // every event: session state (PermissionRequest → needs you)
        let project = Summary.project(cwd: e.cwd)
        switch e.name {
        case "PermissionRequest":
            guard board.isReady else { conn.reply(BridgeReply(decision: nil)); return }
            let gone = PeerGone()
            let reply = e.toolName == "AskUserQuestion"
                ? await askQuestion(e, project: project, conn: conn, gone: gone)
                : await askPermission(e, project: project, conn: conn, gone: gone)
            // Answered on the board, or in the terminal (the hook went away): either way Claude continues.
            // A timeout or a lost board leaves the session "needs you": the terminal prompt is waiting.
            if reply.decision != nil || gone.happened { await hub?.requestAnswered(sessionId: e.sessionId) }
            log("\(project) \(e.toolName ?? "") → \(reply.decision ?? (gone.happened ? "answered in the terminal" : "fall through"))")
            conn.reply(reply)
        default:
            // Stop / Notification / session events: the hub sends the focused session's "done" and the rows
            conn.close()
        }
    }

    private func askPermission(_ e: HookEvent, project: String, conn: any HookConnection,
                               gone: PeerGone) async -> BridgeReply {
        let rule = AnswerMapping.alwaysRule(suggestions: e.permissionSuggestions)
        let tool = e.toolName ?? "Tool"
        let summary = Summary.permission(e)
        let response = await cancellable(conn, gone) { [requests] in
            await requests.ask(shape: .permission(alwaysOffered: rule != nil)) { id in
                [.permission(id: id, project: project, tool: tool, summary: summary, alwaysRule: rule)]
            }
        }
        return response.map { AnswerMapping.permissionReply($0, suggestions: e.permissionSuggestions) }
            ?? BridgeReply(decision: nil)
    }

    private func askQuestion(_ e: HookEvent, project: String, conn: any HookConnection,
                             gone: PeerGone) async -> BridgeReply {
        guard HookSchema.questionAnswers != .terminalOnly, let questions = AskQuestion.parse(e.toolInput) else {
            log("\(project) AskUserQuestion not shown on the board (unsupported); Claude asks in the terminal")
            return BridgeReply(decision: nil)
        }
        let shape = RequestShape.question(options: questions.map { $0.options.count }, multi: questions.map(\.multiSelect))
        let response = await cancellable(conn, gone) { [requests] in
            await requests.ask(shape: shape) { id in
                questions.enumerated().map { i, q in
                    BoardMessage.question(id: id, index: i, count: questions.count, project: project, question: q)
                }
            }
        }
        guard case .answers(let masks, let others) = response else { return BridgeReply(decision: nil) }
        return AnswerMapping.questionReply(masks, others: others, questions: questions, toolInput: e.toolInput)
    }

    /// Runs `body`, cancelling it when the hook goes away (the user answered in the terminal): the queue then
    /// cancels the request on the board.
    private func cancellable(_ conn: any HookConnection, _ gone: PeerGone,
                             _ body: @escaping @Sendable () async -> BoardResponse?) async -> BoardResponse? {
        let task = Task { await body() }
        conn.onPeerGone { gone.mark(); task.cancel() }
        return await task.value
    }
}

/// Set when the hook went away while its request waited for the board (the user answered in the terminal).
private final class PeerGone: @unchecked Sendable {
    private let lock = NSLock()
    private var gone = false

    func mark() { lock.withLock { gone = true } }
    var happened: Bool { lock.withLock { gone } }
}
