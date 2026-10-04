import Foundation

public enum BridgeSocket {
    public static var path: String {
        ProcessInfo.processInfo.environment["CLAUDE_BOARD_SOCK"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-board/sock")
    }
}

/// Daemon → hook, one JSON line
public struct BridgeReply: Codable, Equatable, Sendable {
    public let decision: String?
    public init(decision: String?) { self.decision = decision }
}

public enum HookOutput {
    public static func json(for decision: Decision) -> String {
        let behavior = decision == .allow ? "allow" : "deny"
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\#(behavior)"}}}"#
    }
}

/// Hook side. Writes the event followed by "\n"; if `waitForReply`, reads one line back.
/// Any failure (no daemon, timeout, garbage) returns nil so the caller can fall through.
public func bridgeRoundTrip(event: Data, waitForReply: Bool, timeout: TimeInterval) -> BridgeReply? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = BridgeSocket.path
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: path.utf8)
        buf[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var payload = event
    payload.append(0x0a)
    let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == payload.count, waitForReply else { return nil }

    var line = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0a { break }
        line.append(byte)
    }
    return try? JSONDecoder().decode(BridgeReply.self, from: line)
}
