// Claude Code hook: forwards the event (plus $TMUX_PANE / $TMUX and, inside tmux, its process ancestry) to the
// claude-board daemon. PermissionRequest: prints the board's decision, or nothing (Claude shows its normal prompt).
import ClaudeBoardCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? HookEvent.parse(input) else { exit(0) }

let environment = ProcessInfo.processInfo.environment
let ancestors = (environment["TMUX_PANE"] ?? "").isEmpty ? [] : ProcessTree.chain(from: getppid())
let line = HookEnvelope.augment(input, environment: environment, ancestors: ancestors)
let isPermission = event.name == "PermissionRequest"
// Other events are fire-and-forget: delivered within about 1 s or dropped, never holding up Claude Code
let reply = bridgeRoundTrip(event: line, waitForReply: isPermission, timeout: isPermission ? 92 : 1)

if isPermission, let out = HookOutput.output(for: reply) {
    print(out)
}
exit(0)
