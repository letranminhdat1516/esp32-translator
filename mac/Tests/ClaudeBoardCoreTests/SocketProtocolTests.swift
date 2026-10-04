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

@Test func noDaemonFallsThroughFast() {
    setenv("CLAUDE_BOARD_SOCK", "/tmp/claude-board-test-missing.sock", 1)
    let start = Date()
    let reply = bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: 5)
    #expect(reply == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}
