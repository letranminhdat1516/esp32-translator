import Foundation
import Network
import Testing
@testable import ClaudeBoardCore

/// Lines a test listener received, in order (thread-safe)
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: Data) { lock.withLock { lines.append(String(decoding: line, as: UTF8.self)) } }
    var value: [String] { lock.withLock { lines } }

    /// Waits up to `timeout` for `count` lines, then a little longer so a duplicate would show up too
    func wait(for count: Int, timeout: TimeInterval = 3) async -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while value.count < count && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(200))
        return value
    }
}

/// Runs blocking socket or process work on a GCD thread, never on the test runner's cooperative pool (other
/// tests' short sleeps would starve)
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: body()) } }
}

func send(event: String, to path: String, waitForReply: Bool = false) async -> BridgeReply? {
    await offPool { bridgeRoundTrip(event: Data(event.utf8), waitForReply: waitForReply, timeout: 92, socketPath: path) }
}

private func testSocketPath() -> String { "/tmp/cb-\(UUID().uuidString.prefix(8)).sock" }

/// The daemon's receive loop before the fix (Network.framework, first line, then close), on its own socket:
/// what an installed daemon does with the hook's line
final class NWTestDaemon: @unchecked Sendable {
    let path = testSocketPath()
    let received = Received()
    private let listener: NWListener

    init() throws {
        unlink(path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        listener = try NWListener(using: params)
        let received = received
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            let buffer = LockedData()
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data { buffer.append(data) }
                    if let line = buffer.firstLine() {
                        received.add(line)
                        conn.cancel()
                    } else if !done && error == nil {
                        receive()
                    } else {
                        conn.cancel()
                    }
                }
            }
            receive()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
    }

    deinit {
        listener.cancel()
        unlink(path)
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    func firstLine() -> Data? {
        lock.withLock { data.firstIndex(of: 0x0a).map { Data(data[data.startIndex..<$0]) } }
    }
}

/// claude-board-hook, built next to the test bundle by `swift build` / `swift test`
private let hookBinary: String? = {
    let dirs = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        + [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug")]
    return dirs.map { $0.appendingPathComponent("claude-board-hook").path }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}()

/// Runs the real hook with `event` on stdin against `socket`: (exit status, stdout, seconds)
private func runHook(_ hook: String, event: String, socket: String) async throws -> (Int32, String, Double) {
    try await offPool { Result { try runHookNow(hook, event: event, socket: socket) } }.get()
}

private func runHookNow(_ hook: String, event: String, socket: String) throws -> (Int32, String, Double) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: hook)
    var env = ProcessInfo.processInfo.environment
    env["CLAUDE_BOARD_SOCK"] = socket
    env.removeValue(forKey: "TMUX_PANE")
    env.removeValue(forKey: "TMUX")
    p.environment = env
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    let start = Date()
    try p.run()
    input.fileHandleForWriting.write(Data(event.utf8))
    try input.fileHandleForWriting.close()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self), Date().timeIntervalSince(start))
}

private func notification(_ i: Int) -> String {
    #"{"hook_event_name":"Notification","session_id":"s\#(i)","cwd":"/tmp/p","notification_type":"idle_prompt"}"#
}

// MARK: - Hook side: fire-and-forget events reach the daemon

@Test func fireAndForgetEventsReachTheDaemon() async throws {
    let d = try NWTestDaemon()
    for i in 0..<6 {
        #expect(await send(event: "{\"n\":\(i)}", to: d.path) == nil)
    }
    #expect(await d.received.wait(for: 6) == (0..<6).map { "{\"n\":\($0)}" })
}

@Test func fireAndForgetNeverWaitsLongerThanASecond() async {
    // A daemon that accepts but never reads nor closes: the hook gives up after about 1 s, silently
    let d = FakeDaemon { _ in usleep(2_500_000) }
    let start = Date()
    #expect(await send(event: "{}", to: d.path) == nil)
    let took = Date().timeIntervalSince(start)
    #expect(took > 0.8 && took < 1.6, "\(took)")
    // No daemon at all: immediately
    #expect(await send(event: "{}", to: "/tmp/none-x.sock") == nil)
}

@Test(.enabled(if: hookBinary != nil, "claude-board-hook is not built"))
func realHookDeliversNotificationsToTheDaemon() async throws {
    let hook = try #require(hookBinary)
    let d = try NWTestDaemon()
    for i in 0..<6 {
        let (status, out, took) = try await runHook(hook, event: notification(i), socket: d.path)
        #expect(status == 0 && out.isEmpty && took < 1.5, "\(status) \(out) \(took)")
    }
    let lines = await d.received.wait(for: 6)
    #expect(lines.count == 6, "\(lines)")
    #expect(lines.compactMap { try? HookEvent.parse(Data($0.utf8)).sessionId } == (0..<6).map { "s\($0)" })
}

// MARK: - Daemon side: the socket server hands over every complete line once

/// A HookSocketServer on its own socket that records each line and closes it (like a Notification)
final class TestServer: @unchecked Sendable {
    let received = Received()
    let server: HookSocketServer

    init(maxLineBytes: Int = 4 * 1024 * 1024,
         answer: @escaping @Sendable (Data, any HookConnection) -> Void = { _, conn in conn.close() }) throws {
        let received = received
        server = HookSocketServer(path: testSocketPath(), maxLineBytes: maxLineBytes) { line, conn in
            received.add(line)
            answer(line, conn)
        }
        try server.start()
    }

    var path: String { server.path }
    deinit { server.stop() }
}

/// Connects, writes `bytes`, then closes at once (or half-closes and returns whether the server closed within 2 s)
@discardableResult
private func rawClient(_ path: String, _ bytes: String, waitForClose: Bool = false) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: path.utf8)
        buf[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return false }
    send(fd, bytes)
    guard waitForClose else { return true }
    shutdown(fd, SHUT_WR)
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var b: UInt8 = 0
    return poll(&p, 1, 2000) > 0 && read(fd, &b, 1) == 0
}

@Test func serverDeliversALineWrittenThenClosedAtOnce() async throws {
    let s = try TestServer()
    for i in 0..<20 { #expect(await offPool { rawClient(s.path, "line\(i)\n") }) }
    #expect(await s.received.wait(for: 20).sorted() == (0..<20).map { "line\($0)" }.sorted())
}

@Test func serverDropsAPartialLineAtTheEnd() async throws {
    let s = try TestServer()
    #expect(await offPool { rawClient(s.path, "{\"no\":\"newline\"}", waitForClose: true) })   // and the server closes
    _ = await offPool { rawClient(s.path, "half") }
    #expect(await s.received.wait(for: 1, timeout: 0.5).isEmpty)
}

@Test func serverDeliversEveryCompleteLineInOrder() async throws {
    let s = try TestServer()
    #expect(await offPool { rawClient(s.path, "a\nb\n\nc", waitForClose: true) })
    #expect(await s.received.wait(for: 3) == ["a", "b", ""])
}

@Test func serverDropsAnOversizedLine() async throws {
    let s = try TestServer(maxLineBytes: 16)
    #expect(await offPool { rawClient(s.path, String(repeating: "x", count: 100), waitForClose: true) })
    #expect(await s.received.wait(for: 1, timeout: 0.5).isEmpty)
}

@Test func serverRepliesToAPermissionRequest() async throws {
    let s = try TestServer { _, conn in conn.reply(BridgeReply(decision: "allow")) }
    #expect(await send(event: "{}", to: s.path, waitForReply: true)?.decision == "allow")
    // A large reply (AskUserQuestion echoes the tool input) arrives whole
    let big = String(repeating: "é", count: 2 * 1024 * 1024)
    let b = try TestServer { _, conn in conn.reply(BridgeReply(decision: "deny", message: big)) }
    #expect(await send(event: "{}", to: b.path, waitForReply: true)?.message == big)
}

@Test func serverReportsAHookThatWentAway() async throws {
    // The user answered in the terminal: Claude Code ends the hook while its request waits
    let gone = DispatchSemaphore(value: 0)
    let s = try TestServer { _, conn in conn.onPeerGone { gone.signal() } }
    #expect(await offPool { rawClient(s.path, "{}\n") })
    #expect(await offPool { gone.wait(timeout: .now() + 2) } == .success)
}

@Test func fireAndForgetEventsReachTheServer() async throws {
    let s = try TestServer()
    for i in 0..<6 {
        let start = Date()
        #expect(await send(event: "{\"n\":\(i)}", to: s.path) == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)   // the server closes as soon as the line is handled
    }
    #expect(await s.received.wait(for: 6) == (0..<6).map { "{\"n\":\($0)}" })
}

@Test(.enabled(if: hookBinary != nil, "claude-board-hook is not built"))
func realHookDeliversEventsToTheServer() async throws {
    let hook = try #require(hookBinary)
    let s = try TestServer()
    for i in 0..<6 {
        let (status, out, took) = try await runHook(hook, event: notification(i), socket: s.path)
        #expect(status == 0 && out.isEmpty && took < 1.5, "\(status) \(out) \(took)")
    }
    let prompt = #"{"hook_event_name":"UserPromptSubmit","session_id":"p","cwd":"/tmp/p","prompt":"Viết một bài thơ"}"#
    #expect(try await runHook(hook, event: prompt, socket: s.path).0 == 0)
    let ids = await s.received.wait(for: 7).compactMap { try? HookEvent.parse(Data($0.utf8)) }.map { "\($0.name) \($0.sessionId)" }
    #expect(ids == (0..<6).map { "Notification s\($0)" } + ["UserPromptSubmit p"])
}
