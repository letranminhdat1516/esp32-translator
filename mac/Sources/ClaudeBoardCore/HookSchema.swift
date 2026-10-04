import Foundation

/// How "Always allow" is sent back to Claude Code (verified in the hook spike).
public enum AlwaysAllowStyle: Sendable, Equatable {
    /// No verified mechanism: the board never offers the button
    case unsupported
    /// decision.updatedPermissions = [the first permission_suggestions element, verbatim]
    case suggestionsVerbatim
    /// decision.updatedPermissions = {"rule": <caption>, "remember": true}
    case ruleRemember
}

/// How AskUserQuestion answers reach Claude (verified in the hook spike).
public enum QuestionAnswerStyle: Sendable, Equatable {
    /// allow + updatedInput = tool_input + "answers": {question: "Label" or "A, B"}
    case updatedInputJoined
    /// allow + updatedInput = tool_input + "answers": {question: ["A", "B"]}
    case updatedInputArrays
    /// deny + message "The user answered on the board: Q → A; Q2 → B, C" (the spec's fallback)
    case denyWithReason
    /// Nothing works: questions are never shown on the board (Claude asks in the terminal)
    case terminalOnly
}

/// The hook spike's Decisions table (docs/superpowers/notes/2026-10-04-hook-spike.md), in one place.
/// Note from the spike: only `addRules` suggestions should get the Always allow button
/// (an `addDirectories` suggestion did not stop the re-prompt).
public enum HookSchema {
    /// Key inside hookSpecificOutput.decision whose text Claude sees when a call is denied
    public static let denyMessageKey = "message"
    public static let alwaysAllow: AlwaysAllowStyle = .suggestionsVerbatim
    public static let questionAnswers: QuestionAnswerStyle = .updatedInputJoined
    /// SessionStart / SessionEnd fire from settings hooks (else: 2 h idle fallback)
    /// Keep equal to SESSION_HOOKS in mac/claude_settings.py (which hooks the installer adds).
    public static let sessionHooks = true
}
