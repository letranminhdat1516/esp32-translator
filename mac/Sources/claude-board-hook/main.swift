// Claude Code hook: forwards the event (plus $TMUX_PANE / $TMUX) to the claude-board daemon.
// PermissionRequest: prints the board's decision, or nothing (Claude shows its normal prompt).
import ClaudeBoardCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? HookEvent.parse(input) else { exit(0) }

let line = HookEnvelope.augment(input, environment: ProcessInfo.processInfo.environment)
let isPermission = event.name == "PermissionRequest"
let reply = bridgeRoundTrip(event: line, waitForReply: isPermission, timeout: 92)

if isPermission, let out = HookOutput.output(for: reply) {
    print(out)
}
exit(0)
