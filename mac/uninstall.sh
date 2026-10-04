#!/bin/bash
# mac/uninstall.sh — remove the Claude board bridge and its Claude Code hooks.
# Test overrides: BIN, CLAUDE_SETTINGS, CLAUDE_BOARD_SKIP_LAUNCHD=1
set -euo pipefail
BIN="${BIN:-$HOME/.claude-board/bin}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if [ "${CLAUDE_BOARD_SKIP_LAUNCHD:-0}" != 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
  launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
  rm -f "$PLIST"
fi
rm -rf "$BIN"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
s = json.load(open(path))
hooks = s.get("hooks", {})
for event in list(hooks):
    hooks[event] = [e for e in hooks[event] if not any(h.get("command", "").endswith("claude-board-hook") for h in e.get("hooks", []))]
    if not hooks[event]:
        del hooks[event]
if "hooks" in s and not hooks:
    del s["hooks"]
json.dump(s, open(path, "w"), indent=2)
print("hooks removed from", path)
PY
fi
echo "claude-board uninstalled."
