#!/bin/bash
# mac/install.sh — build and install the Claude board bridge for the current user.
# Test overrides: BIN, CLAUDE_SETTINGS, CLAUDE_BOARD_SKIP_LAUNCHD=1
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="${BIN:-$HOME/.claude-board/bin}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mkdir -p "$BIN" "$(dirname "$SETTINGS")"
cp .build/release/claude-board .build/release/claude-board-hook "$BIN/"

# Settings first: an invalid settings.json aborts before the daemon starts.
python3 claude_settings.py install "$SETTINGS" "$BIN/claude-board-hook"

if [ "${CLAUDE_BOARD_SKIP_LAUNCHD:-0}" != 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
  mkdir -p "$HOME/.claude-board" "$(dirname "$PLIST")"
  python3 claude_settings.py plist dev.cicca.claude-board.plist.template "$PLIST" "$BIN" "$HOME"
  plutil -lint "$PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
echo "claude-board installed. Log: ~/.claude-board/daemon.log"
