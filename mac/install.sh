#!/bin/bash
# mac/install.sh — build and install the Claude board bridge for the current user.
# Test overrides: BIN, CLAUDE_SETTINGS, CLAUDE_BOARD_SKIP_LAUNCHD=1
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="${BIN:-$HOME/.claude-board/bin}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mkdir -p "$BIN"
cp .build/release/claude-board .build/release/claude-board-hook "$BIN/"

if [ "${CLAUDE_BOARD_SKIP_LAUNCHD:-0}" != 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
  mkdir -p "$HOME/.claude-board" "$(dirname "$PLIST")"
  sed -e "s#__BIN__#$BIN#g" -e "s#__HOME__#$HOME#g" dev.cicca.claude-board.plist.template > "$PLIST"
  launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
HOOK="$BIN/claude-board-hook" python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]; hook = os.environ["HOOK"]
s = json.load(open(path))
hooks = s.setdefault("hooks", {})
def ensure(event, entry):
    lst = hooks.setdefault(event, [])
    lst[:] = [e for e in lst if not any(h.get("command", "").endswith("claude-board-hook") for h in e.get("hooks", []))]
    lst.append(entry)
ensure("PermissionRequest", {"matcher": "*", "hooks": [{"type": "command", "command": hook, "timeout": 100}]})
ensure("Stop", {"hooks": [{"type": "command", "command": hook, "async": True}]})
ensure("Notification", {"matcher": "idle_prompt", "hooks": [{"type": "command", "command": hook, "async": True}]})
json.dump(s, open(path, "w"), indent=2)
print("hooks installed in", path)
PY
echo "claude-board installed. Log: ~/.claude-board/daemon.log"
