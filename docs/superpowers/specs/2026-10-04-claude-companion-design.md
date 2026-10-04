# Claude companion mode: design

Date: 2026-10-04. Status: draft for review.

## Goal

Use the ESP32 board to answer Claude Code permission prompts and to get notified when Claude
finishes, without going back to the Mac terminal.

Agreed with the user:
- Claude Code runs on the Mac.
- The board talks to the Mac over BLE, the same way it talks to the iPhone for translation.
  It keeps both links at once.
- v1 works only within BLE range of the Mac (~10 m). Away from the Mac, Claude Code simply
  shows its normal terminal prompt. A relay through the iPhone is a later step.
- Safe by default: no board, no answer, or timeout → Claude Code falls back to its normal prompt.
  Nothing is ever auto-approved.

## User experience

| Event | Board |
|---|---|
| Claude asks for permission | Screen wakes, switches to the Claude screen, a short chime plays. It shows the project folder, the tool and a one-line summary (e.g. `Bash: npm test`), with **Allow** and **Deny** buttons |
| User taps Allow / Deny | Claude Code continues within about 0.5 s. The screen returns to where it was |
| No answer within 90 s | The request disappears from the board. Claude Code shows the terminal prompt |
| Claude finished a turn | Chime + "Claude finished: <project>" toast. The Claude screen shows the last line of Claude's reply |
| PWR double press | Switches between the Translator screen and the Claude screen |

## Architecture

```
Claude Code ──hook (stdin JSON)──► claude-board-hook ──Unix socket──► claude-board (Mac daemon)
                                    (waits for answer)                    │ CoreBluetooth central
                                                                          ▼
                                                                 ESP32 board (2nd BLE link)
```

### 1. Claude Code hooks (`~/.claude/settings.json`)

Verified against https://code.claude.com/docs/en/hooks.md:
- `PermissionRequest` fires only when Claude would show a permission dialog. The hook prints
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}`,
  or prints nothing to fall through to the normal prompt. Configured timeout: 100 s
  (the bridge itself gives up at 90 s).
- `Stop` (Claude finished its turn) and `Notification` with matcher `idle_prompt` run with
  `"async": true` so they never slow Claude down.

### 2. `claude-board-hook` (tiny CLI, Swift)

Reads the hook JSON from stdin and forwards it to the daemon over `~/.claude-board/sock`.
For `PermissionRequest` it waits for the answer and prints the decision JSON. If the daemon
is not running, the board is not connected, or nothing comes back in 90 s, it exits 0 with no
output, so Claude Code falls back to its normal prompt.

### 3. `claude-board` daemon (Swift, launchd user agent)

- Keeps a BLE connection to the board (scans for the board's service UUID, reconnects automatically).
- Queues permission requests from several Claude sessions and sends them to the board one at a time.
- Builds the one-line summary on the Mac (tool name + the most relevant field: command,
  file path, URL), trimmed to fit the screen.
- Only accepts an answer whose request id matches the request it sent.

### 4. Board firmware

- NimBLE allows 2 connections (iPhone + Mac). Translation stays on its existing service;
  Claude gets a new service:

  | Characteristic | Direction | Payload |
  |---|---|---|
  | `claude_request` | Mac → board (write) | `[id u32][kind u8][UTF-8 text]`, chunked like the subtitle text. kind 0 = permission (`project\ntool\nsummary`), 1 = finished (`project\nlast line`), 2 = cancel request `id` |
  | `claude_answer` | board → Mac (notify) | `[id u32][decision u8]`, 1 = allow, 2 = deny |

- New Claude screen in LVGL (status line, request text, Allow/Deny buttons, last event).
  `app_switch_mode()` toggles screens. A permission request forces the Claude screen and wakes
  the display, even after a double-tap screen-off.
- Chime through the ES8311 speaker (short tone generated on the fly, no audio files).
- Translation keeps running in the background while the Claude screen is shown.

## Security

- The board can only answer requests the Mac sent: answers carry the request id, and the daemon
  ignores anything else.
- The daemon remembers the board's BLE identifier after the first connection and only connects to it.
- Deny is always available. Silence never means allow.

## Out of scope for v1

- Remote use through the iPhone (Tailscale relay).
- Choosing "always allow" rules from the board.
- Showing full diffs or long commands.

## Testing

- Daemon + hook: feed recorded `PermissionRequest` / `Stop` JSON into `claude-board-hook`
  with a fake BLE board; check allow, deny, timeout fall-through and daemon-down fall-through.
- Firmware: Mac-side BLE script (bleak) sends requests and checks answers; on-device check of
  screen switching, wake from screen-off and the chime.
- End to end: a real Claude Code session on the Mac running a command that needs permission,
  approved and denied from the board.
