#!/bin/bash
# mac/install.sh — build and install the Claude board bridge for the current user.
# Test overrides: BIN, CLAUDE_SETTINGS, LOCAL_BIN, CLAUDE_BOARD_SKIP_LAUNCHD=1
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="${BIN:-$HOME/.claude-board/bin}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mkdir -p "$BIN" "$(dirname "$SETTINGS")"
# Never overwrite a signed binary in place (same inode → the kernel's code-signature cache can SIGKILL
# the new code on Apple Silicon): copy to a temp name in the same directory, then rename over the old one.
install_bin() {
  local name="$1" tmp="$BIN/.$1.tmp.$$"
  cp ".build/release/$name" "$tmp"
  if [ "$name" = claude-board ]; then
    # Ad-hoc re-sign so the signature binds the embedded Info.plist (Bluetooth usage text, bundle id).
    codesign --force --sign - --identifier dev.cicca.claude-board "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; echo "codesign failed for $name" >&2; exit 1; }
  fi
  mv -f "$tmp" "$BIN/$name"
}
install_bin claude-board
install_bin claude-board-hook
# cb: starts claude inside a marked tmux pane so the board can type voice commands into it
tmp="$BIN/.cb.tmp.$$"
cp cb "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$BIN/cb"
python3 claude_settings.py link-cb "$BIN/cb" "${LOCAL_BIN:-$HOME/.local/bin}"

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
