import Foundation

/// Board answers → the hook's reply. The verified field names and styles live in HookSchema (hook spike);
/// every style is implemented so the spike only has to pick one.
public enum AnswerMapping {
    /// The suggestion "Always allow" would apply, or nil when the button must not be offered.
    /// suggestionsVerbatim (verified): the first `addRules` suggestion with a rules[] array, sent as is; other types
    /// (addDirectories did not stop the re-prompt, setMode) and the {"rule": …} string form are not offerable.
    /// ruleRemember (unverified): the {"rule": …} form is read as well.
    static func usableSuggestion(_ suggestions: JSONValue?, style: AlwaysAllowStyle) -> (suggestion: JSONValue, caption: String)? {
        guard style != .unsupported, let list = suggestions?.array else { return nil }
        for item in list {
            guard let o = item.object else { continue }
            if o["type"]?.string == "addRules", let rules = o["rules"]?.array {
                let names = rules.compactMap { r -> String? in
                    guard let ro = r.object, let tool = ro["toolName"]?.string, !tool.isEmpty else { return nil }
                    if let content = ro["ruleContent"]?.string, !content.isEmpty { return "\(tool)(\(content))" }
                    return tool
                }
                if !names.isEmpty { return (item, names.joined(separator: ", ")) }
            } else if style == .ruleRemember, let rule = o["rule"]?.string, !rule.isEmpty {
                return (item, rule)
            }
        }
        return nil
    }

    /// Caption of the rule "Always allow" would add, or nil when the button must not be offered.
    public static func alwaysRule(suggestions: JSONValue?, style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> String? {
        usableSuggestion(suggestions, style: style)?.caption
    }

    public static func permissionReply(_ r: BoardResponse, suggestions: JSONValue?,
                                       style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> BridgeReply {
        switch r {
        case .allow:
            return BridgeReply(decision: "allow")
        case .deny:
            return BridgeReply(decision: "deny")
        case .alwaysAllow:
            // The user tapped an allow button: without a usable rule it is a plain allow
            guard let usable = usableSuggestion(suggestions, style: style) else { return BridgeReply(decision: "allow") }
            switch style {
            case .suggestionsVerbatim:
                return BridgeReply(decision: "allow", updatedPermissions: .array([usable.suggestion]))
            case .ruleRemember:
                return BridgeReply(decision: "allow",
                                   updatedPermissions: .object(["rule": .string(usable.caption), "remember": .bool(true)]))
            case .unsupported:
                return BridgeReply(decision: "allow")
            }
        case .answers:
            return BridgeReply(decision: nil)
        }
    }

    /// Labels chosen per question, in option order (labels from the original tool_input, never the cut ones).
    public static func chosenLabels(_ masks: [UInt8], _ questions: [AskQuestion]) -> [[String]] {
        zip(masks, questions).map { mask, q in
            q.options.indices.filter { mask & (1 << $0) != 0 }.map { q.options[$0].label }
        }
    }

    /// The spec's fallback text: "The user answered on the board: <question> → <choice>[; …]"
    public static func boardAnswerText(_ masks: [UInt8], questions: [AskQuestion]) -> String {
        let parts = zip(questions, chosenLabels(masks, questions)).map { q, labels in
            "\(q.question) → \(labels.joined(separator: ", "))"
        }
        return "The user answered on the board: " + parts.joined(separator: "; ")
    }

    public static func questionReply(_ masks: [UInt8], questions: [AskQuestion], toolInput: [String: JSONValue],
                                     style: QuestionAnswerStyle = HookSchema.questionAnswers) -> BridgeReply {
        switch style {
        case .denyWithReason:
            return BridgeReply(decision: "deny", message: boardAnswerText(masks, questions: questions))
        case .updatedInputJoined, .updatedInputArrays:
            var answers: [String: JSONValue] = [:]
            for (q, labels) in zip(questions, chosenLabels(masks, questions)) {
                answers[q.question] = style == .updatedInputJoined
                    ? .string(labels.joined(separator: ", "))
                    : .array(labels.map { .string($0) })
            }
            var updated = toolInput
            updated["answers"] = .object(answers)
            return BridgeReply(decision: "allow", updatedInput: .object(updated))
        case .terminalOnly:
            return BridgeReply(decision: nil)
        }
    }
}
