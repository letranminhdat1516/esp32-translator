import Foundation
import Testing
@testable import ClaudeBoardCore

@Test func allowJsonMatchesClaudeCodeSchema() throws {
    let obj = try JSONSerialization.jsonObject(with: Data(HookOutput.json(for: .allow).utf8)) as! [String: Any]
    let out = obj["hookSpecificOutput"] as! [String: Any]
    #expect(out["hookEventName"] as? String == "PermissionRequest")
    #expect((out["decision"] as! [String: Any])["behavior"] as? String == "allow")
}

@Test func denyJson() throws {
    #expect(HookOutput.json(for: .deny).contains(#""behavior":"deny""#))
}

/// One-shot fake daemon: listens on a unique temp socket, accepts one client, runs `handler`.
final class FakeDaemon: @unchecked Sendable {
    let path = "/tmp/cb-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32

    init(handler: @escaping @Sendable (Int32) -> Void) {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(listener, 1)
        let l = listener
        Thread.detachNewThread {
            var p = pollfd(fd: l, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 5000) > 0 {
                let c = accept(l, nil, nil)
                if c >= 0 { handler(c); close(c) }
            }
            close(l)
        }
    }
    deinit { unlink(path) }
}

/// Reads until the request newline arrives (or 2 s pass).
func readRequest(_ fd: Int32) {
    var b: UInt8 = 0
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while poll(&p, 1, 2000) > 0, read(fd, &b, 1) == 1, b != 0x0a {}
}

/// Fake daemons keep writing after the hook side gave up: EPIPE, never a SIGPIPE that kills the test process
func send(_ fd: Int32, _ s: String) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// Holds the connection open without replying until the client goes away (max 3 s).
func holdOpen(_ fd: Int32) {
    var b: UInt8 = 0
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let end = Date().addingTimeInterval(3)
    while Date() < end, poll(&p, 1, 100) >= 0 { if p.revents != 0, read(fd, &b, 1) <= 0 { break } }
}

func roundTrip(_ d: FakeDaemon, timeout: TimeInterval = 2) -> BridgeReply? {
    bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: timeout, socketPath: d.path)
}

@Test func replyAllowAndDenyMapToDecisionJson() {
    let a = FakeDaemon { fd in readRequest(fd); send(fd, #"{"decision":"allow"}"# + "\n") }
    #expect(HookOutput.output(for: roundTrip(a)) == HookOutput.json(for: .allow))
    let d = FakeDaemon { fd in readRequest(fd); send(fd, #"{"decision":"deny"}"# + "\n") }
    #expect(HookOutput.output(for: roundTrip(d)) == HookOutput.json(for: .deny))
}

@Test func garbageRepliesPrintNothing() {
    for body in [#"{"decision":"maybe"}"# + "\n", "not json\n", "\n", #"{"decision":"al"# + "\n", "{}\n", #"{"decision":null}"# + "\n"] {
        let d = FakeDaemon { fd in readRequest(fd); send(fd, body) }
        #expect(HookOutput.output(for: roundTrip(d)) == nil, "body: \(body)")
    }
    #expect(HookOutput.output(for: nil) == nil)
}

@Test func largeAnswerReplyIsAccepted() {
    // 4 questions with long option descriptions: updatedInput is well over 4 KB
    let long = String(repeating: "mô tả dài ", count: 1500)
    let body = #"{"decision":"allow","updatedInput":{"questions":[],"pad":""# + long + #""}}"# + "\n"
    #expect(body.utf8.count > 8192)
    let d = FakeDaemon { fd in readRequest(fd); send(fd, body) }
    let reply = roundTrip(d)
    #expect(reply?.decision == "allow")
    #expect(reply?.updatedInput != nil)
}

@Test func daemonClosesWithoutReplyIsNil() {
    let d = FakeDaemon { fd in readRequest(fd) }
    #expect(roundTrip(d) == nil)
}

@Test func replyWithoutNewlineBeforeCloseIsNil() {
    let d = FakeDaemon { fd in readRequest(fd); send(fd, #"{"decision":"allow"}"#) }
    #expect(roundTrip(d) == nil)
}

@Test func silentDaemonHitsDeadline() {
    let d = FakeDaemon { fd in holdOpen(fd) }
    let start = Date()
    #expect(roundTrip(d, timeout: 0.5) == nil)
    #expect(Date().timeIntervalSince(start) < 1.5)
}

@Test func drippingDaemonHitsAbsoluteDeadline() {
    let d = FakeDaemon { fd in
        readRequest(fd)
        for _ in 0..<30 { send(fd, " "); usleep(100_000) }
    }
    let start = Date()
    #expect(roundTrip(d, timeout: 0.5) == nil)
    #expect(Date().timeIntervalSince(start) < 1.5)
}

@Test func oversizedReplyIsNil() {
    let d = FakeDaemon { fd in readRequest(fd); send(fd, String(repeating: "a", count: 10_000) + "\n") }
    #expect(roundTrip(d) == nil)
}

@Test func daemonThatNeverReadsCannotBlockLargeWrite() {
    let d = FakeDaemon { fd in holdOpen(fd) }  // holdOpen reads 1 byte at a time, far too slow for 8 MB
    let big = Data(repeating: 0x61, count: 8_000_000)
    let start = Date()
    #expect(bridgeRoundTrip(event: big, waitForReply: true, timeout: 0.5, socketPath: d.path) == nil)
    #expect(Date().timeIntervalSince(start) < 1.5)
}

@Test func noDaemonFallsThroughFast() {
    let start = Date()
    let reply = bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: 5,
                                socketPath: "/tmp/claude-board-test-missing.sock")
    #expect(reply == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func staleSocketFileFallsThroughFast() {
    let path = "/tmp/cb-stale-\(UUID().uuidString.prefix(8)).sock"
    let l = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in buf.copyBytes(from: path.utf8); buf[path.utf8.count] = 0 }
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    close(l)  // file remains, nobody listening
    defer { unlink(path) }
    let start = Date()
    #expect(bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: 5, socketPath: path) == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func overlongSocketPathIsNil() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    #expect(bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: 1, socketPath: path) == nil)
}

@Test func nonPositiveTimeoutDoesNotCrashOrHang() {
    let start = Date()
    #expect(bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: -1, socketPath: "/tmp/none-x.sock") == nil)
    #expect(bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: .nan, socketPath: "/tmp/none-x.sock") == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func messageIsOnlySentWithADeny() throws {
    let allow = HookOutput.output(for: BridgeReply(decision: "allow", message: "should not leak"))!
    #expect(!allow.contains("should not leak") && !allow.contains(#""message""#))
    let deny = HookOutput.output(for: BridgeReply(decision: "deny", message: "why"))!
    #expect(deny.contains(#""message":"why""#))
    #expect(HookOutput.output(for: BridgeReply(decision: "ask", message: "x")) == nil)
}
