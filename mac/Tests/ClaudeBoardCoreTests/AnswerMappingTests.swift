import Foundation
import Testing
@testable import ClaudeBoardCore

private let qs = [
    AskQuestion(question: "Which color?", header: "Color",
                options: ["Red", "Green", "Blue"].map { AskOption(label: $0, description: "") }, multiSelect: false),
    AskQuestion(question: "Which fruits?", header: "Fruits",
                options: ["Apple", "Banana", "Cherry"].map { AskOption(label: $0, description: "") }, multiSelect: true),
]
private let input: [String: JSONValue] = ["questions": .array([.string("kept as sent")])]
private let docsSuggestion = JSONValue.array([.object(["rule": .string("Bash(git push *)"),
                                                       "description": .string("Allow git push"),
                                                       "specificity": .string("moderate")])])
private let sdkSuggestion = JSONValue.array([.object(["type": .string("addRules"),
                                                      "rules": .array([.object(["toolName": .string("Bash"),
                                                                                "ruleContent": .string("npm test:*")])]),
                                                      "behavior": .string("allow"),
                                                      "destination": .string("localSettings")])])

@Test func chosenLabelsFollowTheMasks() {
    #expect(AnswerMapping.chosenLabels([0b010, 0b101], qs) == [["Green"], ["Apple", "Cherry"]])
}

@Test func joinedAnswersGoInUpdatedInput() {
    let r = AnswerMapping.questionReply([0b010, 0b101], questions: qs, toolInput: input, style: .updatedInputJoined)
    #expect(r.decision == "allow" && r.message == nil && r.updatedPermissions == nil)
    #expect(r.updatedInput == .object([
        "questions": .array([.string("kept as sent")]),
        "answers": .object(["Which color?": .string("Green"), "Which fruits?": .string("Apple, Cherry")]),
    ]))
}

@Test func arrayAnswersGoInUpdatedInput() {
    let r = AnswerMapping.questionReply([0b001, 0b010], questions: qs, toolInput: input, style: .updatedInputArrays)
    #expect(r.updatedInput?.object?["answers"] == .object(["Which color?": .array([.string("Red")]),
                                                           "Which fruits?": .array([.string("Banana")])]))
}

@Test func denyWithReasonCarriesTheSpecText() {
    let r = AnswerMapping.questionReply([0b010, 0b101], questions: qs, toolInput: input, style: .denyWithReason)
    #expect(r == BridgeReply(decision: "deny",
                             message: "The user answered on the board: Which color? → Green; Which fruits? → Apple, Cherry"))
}

@Test func alwaysRuleReadsBothSuggestionShapes() {
    #expect(AnswerMapping.alwaysRule(suggestions: docsSuggestion, style: .suggestionsVerbatim) == nil)   // only addRules is verified
    #expect(AnswerMapping.alwaysRule(suggestions: docsSuggestion, style: .ruleRemember) == "Bash(git push *)")
    #expect(AnswerMapping.alwaysRule(suggestions: .array([.object(["type": .string("addDirectories")]), sdkSuggestion.array![0]]),
                                     style: .suggestionsVerbatim) == "Bash(npm test:*)")   // skips non-rule suggestions
    #expect(AnswerMapping.alwaysRule(suggestions: sdkSuggestion, style: .ruleRemember) == "Bash(npm test:*)")
    #expect(AnswerMapping.alwaysRule(suggestions: docsSuggestion, style: .unsupported) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: nil, style: .suggestionsVerbatim) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: .array([]), style: .suggestionsVerbatim) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: .array([.object(["type": .string("setMode")])]), style: .suggestionsVerbatim) == nil)
}

@Test func alwaysAllowRepliesWithTheVerifiedRuleShape() {
    let verbatim = AnswerMapping.permissionReply(.alwaysAllow, suggestions: sdkSuggestion, style: .suggestionsVerbatim)
    #expect(verbatim == BridgeReply(decision: "allow", updatedPermissions: .array([sdkSuggestion.array![0]])))
    let remember = AnswerMapping.permissionReply(.alwaysAllow, suggestions: docsSuggestion, style: .ruleRemember)
    #expect(remember == BridgeReply(decision: "allow",
                                    updatedPermissions: .object(["rule": .string("Bash(git push *)"), "remember": .bool(true)])))
    #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: nil, style: .suggestionsVerbatim) == BridgeReply(decision: "allow"))
    #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: docsSuggestion, style: .suggestionsVerbatim) == BridgeReply(decision: "allow"))
    #expect(AnswerMapping.permissionReply(.allow, suggestions: docsSuggestion) == BridgeReply(decision: "allow"))
    #expect(AnswerMapping.permissionReply(.deny, suggestions: docsSuggestion) == BridgeReply(decision: "deny"))
    #expect(AnswerMapping.permissionReply(.answers([1]), suggestions: nil) == BridgeReply(decision: nil))
}

private func addRules(behavior: JSONValue?) -> JSONValue {
    var o: [String: JSONValue] = ["type": .string("addRules"),
                                  "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("rm *")])]),
                                  "destination": .string("localSettings")]
    if let behavior { o["behavior"] = behavior }
    return .object(o)
}

@Test func alwaysAllowIsOnlyOfferedForAllowRules() {
    for style in [AlwaysAllowStyle.suggestionsVerbatim, .ruleRemember] {
        // deny / ask rules must never sit behind an "Always allow" button
        #expect(AnswerMapping.alwaysRule(suggestions: .array([addRules(behavior: .string("deny"))]), style: style) == nil)
        #expect(AnswerMapping.alwaysRule(suggestions: .array([addRules(behavior: .string("ask"))]), style: style) == nil)
        #expect(AnswerMapping.alwaysRule(suggestions: .array([addRules(behavior: .bool(true))]), style: style) == nil)
        // behavior absent counts as allow
        #expect(AnswerMapping.alwaysRule(suggestions: .array([addRules(behavior: nil)]), style: style) == "Bash(rm *)")
        #expect(AnswerMapping.alwaysRule(suggestions: .array([addRules(behavior: .string("allow"))]), style: style) == "Bash(rm *)")
    }
    // a deny suggestion first: the later allow one is the one offered and applied
    let mixed = JSONValue.array([addRules(behavior: .string("deny")), sdkSuggestion.array![0]])
    #expect(AnswerMapping.alwaysRule(suggestions: mixed, style: .suggestionsVerbatim) == "Bash(npm test:*)")
    #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: mixed, style: .suggestionsVerbatim)
            == BridgeReply(decision: "allow", updatedPermissions: .array([sdkSuggestion.array![0]])))
    // tapping Always allow on a deny-only suggestion list is a plain allow, never the deny rule
    #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: .array([addRules(behavior: .string("deny"))]),
                                          style: .suggestionsVerbatim) == BridgeReply(decision: "allow"))
}

@Test func nonArraySuggestionsAreNotOffered() throws {
    for raw in [#"{"type":"addRules","behavior":"allow","rules":[{"toolName":"Bash"}]}"#, #""Bash(*)""#, "42", "null", "true"] {
        let e = try HookEvent.parse(Data((#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{},"permission_suggestions":"# + raw + "}").utf8))
        #expect(AnswerMapping.alwaysRule(suggestions: e.permissionSuggestions, style: .suggestionsVerbatim) == nil)
        #expect(AnswerMapping.alwaysRule(suggestions: e.permissionSuggestions, style: .ruleRemember) == nil)
        #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: e.permissionSuggestions, style: .suggestionsVerbatim)
                == BridgeReply(decision: "allow"))
    }
}
