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
