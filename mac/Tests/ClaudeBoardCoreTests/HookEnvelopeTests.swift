import Foundation
import Testing
@testable import ClaudeBoardCore

private func object(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

@Test func envelopeAddsTmuxPaneAndSocket() throws {
    let raw = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/p"}"#.utf8)
    let out = HookEnvelope.augment(raw, environment: ["TMUX_PANE": "%3", "TMUX": "/private/tmp/tmux-501/default,123,0"])
    let o = object(out)
    #expect(o["claude_board_tmux_pane"] as? String == "%3")
    #expect(o["claude_board_tmux"] as? String == "/private/tmp/tmux-501/default,123,0")
    #expect(o["session_id"] as? String == "s")
    #expect(!out.contains(0x0a))   // one line on the socket
    let e = try HookEvent.parse(out)
    #expect(e.tmuxPane == "%3" && e.tmuxSocket == "/private/tmp/tmux-501/default,123,0")
}

@Test func envelopeWithoutTmuxKeepsTheEvent() throws {
    let raw = Data("{\"hook_event_name\":\"Stop\",\n\"session_id\":\"s\"}\n".utf8)
    let out = HookEnvelope.augment(raw, environment: ["TMUX_PANE": ""])
    #expect(object(out)["claude_board_tmux_pane"] == nil)
    #expect(object(out)["session_id"] as? String == "s")
    #expect(!out.contains(0x0a))
    #expect(try HookEvent.parse(out).tmuxPane == nil)
}

@Test func envelopeLeavesGarbageAlone() {
    let raw = Data("not json".utf8)
    #expect(HookEnvelope.augment(raw, environment: ["TMUX_PANE": "%1"]) == raw)
}

@Test func parsesPermissionSuggestions() throws {
    let e = try HookEvent.parse(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push"},"permission_suggestions":[{"rule":"Bash(git push *)","description":"Allow git push","specificity":"moderate"}]}"#.utf8))
    #expect(e.permissionSuggestions?.array?.first?.object?["rule"]?.string == "Bash(git push *)")
    let none = try HookEvent.parse(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","permission_suggestions":null}"#.utf8))
    #expect(none.permissionSuggestions == nil)
}

@Test func outputCarriesDenyMessageUnderTheVerifiedKey() throws {
    let s = try #require(HookOutput.output(for: BridgeReply(decision: "deny", message: "The user answered on the board: Q → A")))
    let decision = (object(Data(s.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(decision?["behavior"] as? String == "deny")
    #expect(decision?[HookSchema.denyMessageKey] as? String == "The user answered on the board: Q → A")
    #expect(decision?["updatedInput"] == nil)
}

@Test func outputCarriesUpdatedInputAndPermissionsOnlyWhenAllowing() throws {
    let input = JSONValue.object(["questions": .array([]), "answers": .object(["Q?": .string("A")])])
    let perms = JSONValue.array([.object(["rule": .string("Bash(npm test:*)")])])
    let allow = try #require(HookOutput.output(for: BridgeReply(decision: "allow", updatedInput: input, updatedPermissions: perms)))
    let d = (object(Data(allow.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(((d?["updatedInput"] as? [String: Any])?["answers"] as? [String: Any])?["Q?"] as? String == "A")
    #expect(((d?["updatedPermissions"] as? [Any])?.first as? [String: Any])?["rule"] as? String == "Bash(npm test:*)")

    let deny = try #require(HookOutput.output(for: BridgeReply(decision: "deny", updatedInput: input, updatedPermissions: perms)))
    let dd = (object(Data(deny.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(dd?["updatedInput"] == nil && dd?["updatedPermissions"] == nil)
}

@Test func onlyExplicitDecisionsBecomeOutput() {
    #expect(HookOutput.output(for: nil) == nil)
    #expect(HookOutput.output(for: BridgeReply(decision: nil, message: "x")) == nil)
    #expect(HookOutput.output(for: BridgeReply(decision: "ask")) == nil)
}

@Test func oldReplyLinesStillDecode() throws {
    let r = try JSONDecoder().decode(BridgeReply.self, from: Data(#"{"decision":"allow"}"#.utf8))
    #expect(r == BridgeReply(decision: "allow"))
    let enc = String(data: try JSONEncoder().encode(BridgeReply(decision: nil)), encoding: .utf8)
    #expect(enc == "{}")
}
