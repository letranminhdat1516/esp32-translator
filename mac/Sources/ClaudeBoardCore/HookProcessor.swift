import Foundation

/// The BLE link to the board, as the daemon's request handling sees it.
public protocol BoardLinking: Sendable {
    /// Subscribed to the board's answer characteristic: messages can be delivered and answered.
    var isReady: Bool { get }
    func send(_ message: BoardMessage)
}

/// One accepted hook connection on the daemon's Unix socket.
public protocol HookConnection: Sendable {
    /// Calls `handler` (possibly more than once) when the hook side goes away: EOF, error, or the connection
    /// being closed. Harmless after the reply has been sent.
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
        if let request = await accept(line, conn) { await request() }
    }

    /// The part of `process` that must follow arrival order: parses the line, releases a hook that waits for
    /// nothing, and records the event's session state. Returns the request's wait for the board (run it on its
    /// own task, so one request never holds up the hooks behind it), nil when there is nothing to answer.
    func accept(_ line: Data, _ conn: any HookConnection) async -> (@Sendable () async -> Void)? {
        guard let e = try? HookEvent.parse(line) else { conn.close(); return nil }
        // Stop / Notification / session events: nothing to answer, so release the hook (it waits for the close)
        // before the board work
        let isRequest = e.name == "PermissionRequest"
        if !isRequest { conn.close() }
        await hub?.record(e)       // every event: session state (PermissionRequest → needs you)
        guard isRequest else { return nil }   // already closed; the hub sent the focused session's "done" and the rows
        return { await self.answer(e, conn) }
    }

    private func answer(_ e: HookEvent, _ conn: any HookConnection) async {
        let project = Summary.project(cwd: e.cwd)
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

/// Hook lines from the socket, handled one at a time in arrival order (like the daemon's board events): the
/// session state of each line is recorded before the next line's, so a late Stop never overtakes the prompt that
/// came before it. A request's wait for the board runs on its own task.
public final class HookFeed: Sendable {
    public typealias Accept = @Sendable (Data, any HookConnection) async -> (@Sendable () async -> Void)?
    private let lines: AsyncStream<(Data, any HookConnection)>.Continuation

    public convenience init(_ processor: HookProcessor) {
        self.init(accept: { await processor.accept($0, $1) })
    }

    init(accept: @escaping Accept) {
        let (stream, lines) = AsyncStream<(Data, any HookConnection)>.makeStream()
        self.lines = lines
        Task {
            for await (line, conn) in stream {
                if let request = await accept(line, conn) { Task { await request() } }
            }
        }
    }

    public func submit(_ line: Data, _ conn: any HookConnection) { lines.yield((line, conn)) }

    deinit { lines.finish() }
}

/// Set when the hook went away while its request waited for the board (the user answered in the terminal).
private final class PeerGone: @unchecked Sendable {
    private let lock = NSLock()
    private var gone = false

    func mark() { lock.withLock { gone = true } }
    var happened: Bool { lock.withLock { gone } }
}
