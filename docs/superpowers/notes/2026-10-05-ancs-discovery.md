# ANCS discovery on the user's iPhone (2026-10-05)

> **Status: template — every finding below is pending on-device.** The firmware for this probe (Phase 4 Task 1)
> was built and host-tested overnight but not flashed: the board stays on Phase 3 until the user runs the steps
> below. `ANCS_CLAUDE_APP_ID` in `firmware/main/ancs.h` is the unverified guess `com.anthropic.claude` until row 5
> confirms or corrects it.

iPhone model / iOS version: _pending on-device_ (Settings → General → About). Claude app version: _pending on-device_
(App Store page).
Board firmware: Phase 4 Task 1 (discovery probe). Method: Phase 4 plan Task 1 Step 11, rows 1–9.

## How to run it

1. Flash: `cd firmware && . ~/esp/esp-idf/export.sh && idf.py -p /dev/cu.usbmodem1101 flash monitor`
   (the NVS keeps the Mac's bond; the iPhone was never bonded before).
2. On the iPhone first: Settings → Notifications → Claude → Allow Notifications **on**, Show Previews **Always**.
   Record the setting found before changing it (PREVIEWS row).
3. Follow the table, watching the monitor for `ble:` and `ancs:` lines. Paste the lines into "Log excerpts".

| # | Do | Log lines to capture (exact format the firmware prints) |
|---|---|---|
| 1 | Open the translator app on the iPhone | `I (…) ble: iPhone audio on` → `I (…) ble: link N: asking for encryption (rc R)`. iOS "Bluetooth Pairing Request … ESP-Translator"? Tap **Pair**. Then `I (…) ble: link N: encryption on (status 0)` (or `encryption failed (status S)`), `I (…) ancs: link N: ANCS at 0xAAAA..0xBBBB`, then either `I (…) ancs: link N: iPhone notifications on (discovery probe)` or `W (…) ancs: Data Source subscription refused: status 0x…` / `W (…) ancs: Notification Source subscription refused: status 0x…` followed by `I (…) ancs: link N: iPhone notifications not available on this link`. Record which, and whether it came before or after the next prompt |
| 2 | (if iOS asks) "Allow ESP-Translator to receive your notifications?" or similar | The exact prompt text; allow it. Settings → Bluetooth → (i) next to ESP-Translator: is there a **Share System Notifications** toggle, and is it on? |
| 3 | Mac daemon running (connects as before) | Mac link: `I (…) ble: link M: encryption on (status 0)` then `I (…) ancs: link M: no iPhone notification service (not an iPhone, or not shared)`. Claude permission requests on the board still work |
| 4 | Notification from another app (Messages from another device, a Reminders alert) | Only `I (…) ancs: source: event 0 flags 0x.. category C count K uid U` and `I (…) ancs: uid U app "com.apple.…"`. No title, no message |
| 5 | Make the Claude app notify: (a) Mac Claude Code session with `/remote-control`, lock the iPhone, make Claude ask for a permission (e.g. "run `ls` in a shell"); (b) a Remote Control turn finishes while locked; (c) long chat reply in the Claude app, lock before it finishes | For each: `ancs: source: …` (category), `ancs: uid U app "…"` (**the bundle id**), then the details block: `ancs: uid U details (flags 0x.., positive action yes/no, negative action yes/no):`, `ancs:   title (N bytes): "…"`, `ancs:   subtitle (N bytes): "…"`, `ancs:   message (N bytes): "…"`, `ancs:   positive label (N bytes): "…"`, `ancs:   negative label (N bytes): "…"` (any may read `(missing)`). Is the message present while locked? |
| 6 | Swipe one Claude notification away on the iPhone | `ancs: source: event 2 flags … uid U` for that uid |
| 7 | Close the translator app (swipe away in the app switcher), wait 1 min | Link kept (no `ble: disconnected, reason 0x…`)? Another Claude notification still arrives? |
| 8 | Reset the board (RST) with the app still closed, wait 2 min | iPhone reconnects on its own? `ble: connected (…)`, `ble: link N: encryption on`, `ancs: … iPhone notifications on (discovery probe)`; and `ble: iPhone audio subscription restored from the bond: waiting for the app` with **no** `ble: iPhone audio on`. (Encryption on a reconnect without the app may only come with Task 6: record what happens, not a failure) |
| 9 | Open the translator app again | `ble: iPhone audio on` (the app's own CCCD write); translation works as before |

Stop rule: if row 1 shows no pairing prompt and no `encryption on`, capture the `asking for encryption (rc …)` /
`encryption failed (status …)` lines and stop — the security request path needs fixing first.
Other useful warnings: `ancs: probe: request for U refused, status 0x…`, `ancs: probe: bad reply for U`,
`ancs: probe: N stray Data Source bytes`, `ancs: probe: Notification Source of N bytes`.

## Decisions

| Name | Value | Evidence |
|---|---|---|
| CLAUDE_APP_ID | _pending on-device_ (assumed `com.anthropic.claude`) | the `uid … app "…"` lines of row 5 (a), (b), (c) |
| ACTIONS | _pending on-device_ (`<positive label / none>`, `<negative label / none>` per notification kind) | the details blocks of row 5: flags and labels |
| CONTENT | _pending on-device_ (title / subtitle / message per kind, shortened) | row 5 details blocks; message present while locked: _pending_ |
| PROMPTS | _pending on-device_ (pairing prompt text; notification-sharing prompt text; subscription before/after allowing: ok / refused (status)) | rows 1–2 |
| PREVIEWS | _pending on-device_ (Show Previews setting found; content arrived while locked) | row 5 |
| NO_APP_LINK | _pending on-device_ (link kept with the app closed: yes / no; reconnect after a board reset without the app: yes / no (seconds)) | rows 7–8 |

After filling: if CLAUDE_APP_ID differs from `com.anthropic.claude`, change `ANCS_CLAUDE_APP_ID` in
`firmware/main/ancs.h`. If Claude notifications carry no positive / negative actions, note it here (Task 5 still
ships the buttons; they only appear when iOS offers actions).

## Log excerpts

_pending on-device_ — paste the relevant `ancs:` / `ble:` lines for rows 1, 2, 5 and 8. No other app's notification
content appears in the log by construction (only its bundle id); delete any line that shows more than that.
