#!/bin/bash
# mac/uninstall.sh — remove the Claude board bridge and its Claude Code hooks.
# Test overrides: BIN, CLAUDE_SETTINGS, LOCAL_BIN, CLAUDE_BOARD_SKIP_LAUNCHD=1
set -euo pipefail
cd "$(dirname "$0")"
BIN="${BIN:-$HOME/.claude-board/bin}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# Hooks first (aborts on invalid settings), then the agent, then the binaries.
python3 claude_settings.py uninstall "$SETTINGS"

if [ "${CLAUDE_BOARD_SKIP_LAUNCHD:-0}" != 1 ]; then
  launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
  rm -f "$HOME/.claude-board/relay.secret"   # the iPhone pairing stops working; pair again after reinstalling
fi
python3 claude_settings.py unlink-cb "$BIN/cb" "${LOCAL_BIN:-$HOME/.local/bin}"
rm -f "$BIN/claude-board" "$BIN/claude-board-hook" "$BIN/cb"
rmdir "$BIN" 2>/dev/null || true
echo "claude-board uninstalled."
