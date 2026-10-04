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

/// Handles one hook event line received by the daemon. Never decides on its own: a permission request is
/// answered only with what the board sent back, and every failure path replies `null` or nothing.
public struct HookProcessor: Sendable {
    public let board: any BoardLinking
    public let requests: RequestQueue
    private let log: @Sendable (String) -> Void

    public init(board: any BoardLinking, requests: RequestQueue, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.board = board
        self.requests = requests
        self.log = log
    }

    public func process(_ line: Data, _ conn: any HookConnection) async {
        guard let e = try? HookEvent.parse(line) else { conn.close(); return }
        let project = Summary.project(cwd: e.cwd)
        switch e.name {
        case "PermissionRequest":
            guard board.isReady else { conn.reply(BridgeReply(decision: nil)); return }
            let requests = self.requests
            let ask = Task {
                await requests.ask(project: project, tool: e.toolName ?? "Tool", summary: Summary.permission(e))
            }
            // If the hook goes away (user answered in the terminal), cancel the board request.
            conn.onPeerGone { ask.cancel() }
            let d = await ask.value
            let decision: String? = switch d {
            case .allow?: "allow"
            case .deny?: "deny"
            default: nil
            }
            log("\(project) \(e.toolName ?? "") → \(decision ?? "fall through")")
            conn.reply(BridgeReply(decision: decision))
        case "Stop", "Notification":
            if board.isReady {
                let text = e.name == "Stop" ? Summary.lastLine(e) : "Claude is waiting for you"
                await requests.notifyFinished(project: project, line: text)
            }
            conn.close()
        default:
            conn.close()
        }
    }
}
