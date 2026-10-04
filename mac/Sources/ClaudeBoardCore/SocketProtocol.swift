import Foundation

public enum BridgeSocket {
    public static var path: String {
        ProcessInfo.processInfo.environment["CLAUDE_BOARD_SOCK"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-board/sock")
    }
}

/// Daemon → hook, one JSON line. Only `decision` "allow" or "deny" ever becomes a decision; the other
/// fields ride along with it (HookOutput decides which apply).
public struct BridgeReply: Codable, Equatable, Sendable {
    public let decision: String?
    /// Text Claude sees (deny reason, or the board's answers in the deny-with-reason fallback)
    public let message: String?
    /// Allow only: replaces the tool input (AskUserQuestion answers)
    public let updatedInput: JSONValue?
    /// Allow only: the "Always allow" rule
    public let updatedPermissions: JSONValue?

    public init(decision: String?, message: String? = nil, updatedInput: JSONValue? = nil,
                updatedPermissions: JSONValue? = nil) {
        self.decision = decision
        self.message = message
        self.updatedInput = updatedInput
        self.updatedPermissions = updatedPermissions
    }
}

public enum HookOutput {
    public static func json(for decision: Decision) -> String {
        output(for: BridgeReply(decision: decision == .allow ? "allow" : "deny"))!
    }

    /// Maps the daemon reply to the text the hook prints. nil = print nothing (Claude shows its normal prompt).
    /// Only an explicit "allow" or "deny" is ever turned into a decision.
    public static func output(for reply: BridgeReply?) -> String? {
        guard let reply, let behavior = reply.decision, behavior == "allow" || behavior == "deny" else { return nil }
        var decision: [String: JSONValue] = ["behavior": .string(behavior)]
        if let m = reply.message, !m.isEmpty { decision[HookSchema.denyMessageKey] = .string(m) }
        if behavior == "allow" {
            if let u = reply.updatedInput { decision["updatedInput"] = u }
            if let p = reply.updatedPermissions { decision["updatedPermissions"] = p }
        }
        let out = JSONValue.object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(decision),
        ])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(out)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private func monotonicNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// Waits until `fd` is ready for `events` or the deadline passes. true = ready.
private func waitReady(_ fd: Int32, _ events: Int16, deadline: Double) -> Bool {
    while true {
        let remaining = deadline - monotonicNow()
        if remaining <= 0 { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        let ms = Int32(min(remaining * 1000, 60_000).rounded(.up))
        let r = poll(&p, 1, ms)
        if r > 0 { return true }
        if r < 0 && errno != EINTR { return false }
    }
}

/// Longest reply line accepted from the daemon.
let maxReplyBytes = 4096

/// Hook side. Writes the event followed by "\n"; if `waitForReply`, reads one line back.
/// The whole round trip (write + read) shares one absolute deadline of `timeout` seconds.
/// Any failure (no daemon, timeout, oversized or garbage reply) returns nil so the caller can fall through.
public func bridgeRoundTrip(
    event: Data, waitForReply: Bool, timeout: TimeInterval,
    socketPath: String = BridgeSocket.path
) -> BridgeReply? {
    let seconds = timeout.isFinite && timeout > 0 ? timeout : 0.01
    let deadline = monotonicNow() + seconds

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: socketPath.utf8)
        buf[socketPath.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    var payload = event
    payload.append(0x0a)
    var offset = 0
    while offset < payload.count {
        let n = payload.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if n > 0 { offset += n; continue }
        if n < 0 && errno == EINTR { continue }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            guard waitReady(fd, Int16(POLLOUT), deadline: deadline) else { return nil }
            continue
        }
        return nil
    }
    guard waitForReply else { return nil }

    var line = Data()
    var chunk = [UInt8](repeating: 0, count: 512)
    while true {
        guard waitReady(fd, Int16(POLLIN), deadline: deadline) else { return nil }
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard n > 0 else { return nil }  // EOF or error before a full line
        if let nl = chunk[0..<n].firstIndex(of: 0x0a) {
            line.append(contentsOf: chunk[0..<nl])
            break
        }
        line.append(contentsOf: chunk[0..<n])
        if line.count > maxReplyBytes { return nil }
    }
    guard line.count <= maxReplyBytes else { return nil }
    return try? JSONDecoder().decode(BridgeReply.self, from: line)
}
