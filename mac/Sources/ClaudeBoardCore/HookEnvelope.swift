import Foundation

/// Hook side: the hook process inherits Claude Code's environment, so it can tell the daemon which tmux pane
/// the session runs in, and its own process ancestry so the daemon can later check that the pane still runs this
/// session (voice typing). Keys are prefixed so they never clash with Claude's.
public enum HookEnvelope {
    public static func augment(_ event: Data, environment: [String: String], ancestors: [Int32] = []) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any] else { return event }
        if let pane = environment["TMUX_PANE"], !pane.isEmpty {
            obj["claude_board_tmux_pane"] = pane
            if !ancestors.isEmpty { obj["claude_board_pids"] = ancestors.map { Int($0) } }
        }
        if let tmux = environment["TMUX"], !tmux.isEmpty { obj["claude_board_tmux"] = tmux }
        // Compact JSON has no raw newlines: the daemon reads exactly one line
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? event
    }
}
