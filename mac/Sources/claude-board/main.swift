// claude-board: bridges Claude Code hooks (Unix socket) to the ESP32 board (BLE).
import ClaudeBoardCore
import Foundation
import Network

func log(_ s: String) { FileHandle.standardError.write(Data("[claude-board] \(s)\n".utf8)) }

let board = BoardLink()
let requests = RequestQueue(send: { board.send($0) })
board.onAnswer = { a in Task { await requests.handle(a) } }
board.onConnectionChange = { up in if !up { Task { await requests.boardDisconnected() } } }

// Socket: ~/.claude-board/sock, owner-only
let path = BridgeSocket.path
try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
unlink(path)
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
let listener = try NWListener(using: params)

/// Accumulates bytes until the first newline. Only touched from the connection's receive callbacks.
final class LineBuffer: @unchecked Sendable { var data = Data() }

func handle(_ conn: NWConnection) {
    conn.start(queue: .global())
    let buffer = LineBuffer()
    @Sendable func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data { buffer.data.append(data) }
            if let nl = buffer.data.firstIndex(of: 0x0a) {
                let line = buffer.data[buffer.data.startIndex..<nl]
                Task { await process(Data(line), conn) }
            } else if !done && error == nil {
                receive()
            } else {
                conn.cancel()
            }
        }
    }
    receive()
}

func process(_ line: Data, _ conn: NWConnection) async {
    guard let e = try? HookEvent.parse(line) else { conn.cancel(); return }
    let project = Summary.project(cwd: e.cwd)
    switch e.name {
    case "PermissionRequest":
        guard board.isReady else { reply(nil, conn); return }
        // If the hook goes away (user answered in the terminal), cancel the board request
        let ask = Task { await requests.ask(project: project, tool: e.toolName ?? "Tool", summary: Summary.permission(e)) }
        conn.stateUpdateHandler = { state in
            if case .cancelled = state { ask.cancel() }
            if case .failed = state { ask.cancel() }
        }
        let d = await ask.value
        log("\(project) \(e.toolName ?? "") → \(d.map { $0 == .allow ? "allow" : "deny" } ?? "fall through")")
        reply(d, conn)
    case "Stop", "Notification":
        if board.isReady {
            let text = e.name == "Stop" ? Summary.lastLine(e) : "Claude is waiting for you"
            await requests.notifyFinished(project: project, line: text)
        }
        conn.cancel()
    default:
        conn.cancel()
    }
}

func reply(_ d: Decision?, _ conn: NWConnection) {
    let r = BridgeReply(decision: d.map { $0 == .allow ? "allow" : "deny" })
    var data = (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
    data.append(0x0a)
    conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
}

listener.newConnectionHandler = handle
listener.stateUpdateHandler = { s in
    if case .ready = s { chmod(path, 0o600); log("listening on \(path)") }
    if case .failed(let e) = s { log("listener failed: \(e)"); exit(1) }
}
listener.start(queue: .main)
dispatchMain()
