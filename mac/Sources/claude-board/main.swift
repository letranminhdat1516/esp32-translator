// claude-board: bridges Claude Code hooks (Unix socket) to the ESP32 board (BLE).
import ClaudeBoardCore
import Foundation
import Network

func log(_ s: String) { FileHandle.standardError.write(Data("[claude-board] \(s)\n".utf8)) }

// Self-test: claude-board --transcribe FILE (no board, no socket)
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--transcribe" {
    if #available(macOS 26.0, *) {
        let path = CommandLine.arguments[2]
        Task { exit(await transcribeFile(path)) }
        dispatchMain()
    } else {
        print("voice needs macOS 26")
        exit(1)
    }
}

let board = BoardLink()
let requests = RequestQueue(send: { board.send($0) })
let hub = SessionHub(sessionHooks: HookSchema.sessionHooks,
                     post: { await requests.post($0) },
                     finished: { await requests.notifyFinished(project: $0, line: $1) })
// Board events reach the hub in arrival order (a mode flip must never overtake a disconnect)
let (hubEvents, hubFeed) = AsyncStream<@Sendable () async -> Void>.makeStream()
Task { for await event in hubEvents { await event() } }
// Voice: on-device dictation (macOS 26), typing into verified cb panes. Voice inputs and audio packets reach the
// hub in board order through one serial stream (the stop input follows the last packet).
let voiceEngine: (any VoiceEngine)? = {
    if #available(macOS 26.0, *) { return SpeechEngine() }
    return nil
}()
let voice = VoiceHub(engine: voiceEngine, typer: TmuxTyper.system(), requests: requests,
                     target: { await hub.voiceTarget(handle: $0) }, log: log)
let (voiceEvents, voiceFeed) = AsyncStream<@Sendable () async -> Void>.makeStream()
Task { for await event in voiceEvents { await event() } }
board.onVoiceAudio = { packet in voiceFeed.yield { await voice.audio(packet) } }
if let voiceEngine {
    // Asks for Speech Recognition once and installs the model ahead of the first capture
    Task {
        if let why = await voiceEngine.prepare() { log("voice unavailable: \(why)") }
        else { log("voice ready (\(VoiceConfig.localeIdentifier))") }
    }
} else {
    log("voice unavailable: needs macOS 26")
}
board.onInput = { input in
    switch input {
    case .choice, .answers:          // answers to the request on the board
        Task { await requests.handle(input) }
    case .mode, .focus:              // board events: which screen it shows, which session to focus
        if case .mode(let m) = input { log("board mode \(m)") }
        hubFeed.yield { await hub.boardInput(input) }
    case .voiceStart, .voiceStop, .voiceCancel, .voiceSend:   // voice captures (Speak, Other, Deny + why)
        voiceFeed.yield { await voice.input(input) }
    }
}
board.onConnectionChange = { up in
    if up {
        board.send(.timeSync())   // the board has no clock of its own: set it on every connect
    } else {
        Task { await requests.boardDisconnected() }
        voiceFeed.yield { await voice.boardDisconnected() }
    }
    hubFeed.yield { await hub.boardConnected(up) }
}
// Keep the board clock right when the Mac's clock or time zone changes (manual set, network time, travel).
// board.send drops the message unless the link is ready; the next connect sends the time anyway.
for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
        NSTimeZone.resetSystemTimeZone()
        log("\(note.name.rawValue): resending the time")
        board.send(.timeSync())
    }
}
let processor = HookProcessor(board: board, requests: requests, hub: hub, log: log)

// Session expiry (ended → dropped after 10 min; 2 h fallback without session hooks)
let expiryTimer = DispatchSource.makeTimerSource(queue: .main)
expiryTimer.schedule(deadline: .now() + 60, repeating: 60)
expiryTimer.setEventHandler { Task { await hub.tick() } }
expiryTimer.resume()

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
let maxLineBytes = 4 * 1024 * 1024

final class LineBuffer: @unchecked Sendable { var data = Data() }

func handle(_ conn: NWConnection) {
    conn.start(queue: .global())
    let buffer = LineBuffer()
    @Sendable func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data { buffer.data.append(data) }
            if buffer.data.count > maxLineBytes { conn.cancel(); return }   // oversized: drop, no reply
            if let nl = buffer.data.firstIndex(of: 0x0a) {
                let line = buffer.data[buffer.data.startIndex..<nl]
                Task { await processor.process(Data(line), NWHookConnection(conn: conn)) }
            } else if !done && error == nil {
                receive()
            } else {
                conn.cancel()
            }
        }
    }
    receive()
}

/// NWConnection as seen by the core request handling.
struct NWHookConnection: HookConnection {
    let conn: NWConnection

    func onPeerGone(_ handler: @escaping @Sendable () -> Void) {
        // A peer close only surfaces through a pending receive; the hook sends nothing after its line,
        // so any completion (EOF, error, or stray byte) means it is gone.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in handler() }
        conn.stateUpdateHandler = { state in
            if case .cancelled = state { handler() }
            if case .failed = state { handler() }
        }
    }

    func reply(_ reply: BridgeReply) {
        var data = (try? JSONEncoder().encode(reply)) ?? Data("{}".utf8)
        data.append(0x0a)
        conn.send(content: data, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    func close() { conn.cancel() }
}

listener.newConnectionHandler = handle
listener.stateUpdateHandler = { s in
    if case .ready = s { chmod(path, 0o600); log("listening on \(path)") }
    if case .failed(let e) = s { log("listener failed: \(e)"); exit(1) }
}
listener.start(queue: .main)
dispatchMain()
