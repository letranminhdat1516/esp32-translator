# ANCS discovery on the user's iPhone (2026-10-05)

> **Status: template — every finding below is pending on-device.** The firmware for this probe (Phase 4 Task 1)
> was built and host-tested overnight but not flashed: the board stays on Phase 3 until the user runs the steps
> below. The Claude bundle id is already confirmed (see CLAUDE_APP_ID); row 5 only double-checks it over ANCS.

iPhone model / iOS version: _pending on-device_ (Settings → General → About). Claude app version: 1.260925.19
(`devicectl` app list of the user's iPhone, 2026-10-05).
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
| 9 | Open the translator app again | If row 8 restored the subscription: `ble: translator app active on the restored link` then `ble: iPhone audio on` (the app's time / mic write; its CCCD write is unchanged so NimBLE reports nothing). Otherwise just `ble: iPhone audio on`. Translation works as before (audio streams, board mic toggles) |

Stop rule: if row 1 shows no pairing prompt and no `encryption on`, capture the `asking for encryption (rc …)` /
`encryption failed (status …)` lines and stop — the security request path needs fixing first.
Other useful warnings: `ancs: probe: request for U refused, status 0x…`, `ancs: probe: bad reply for U`,
`ancs: probe: N stray Data Source bytes`, `ancs: probe: Notification Source of N bytes`.

## Decisions

| Name | Value | Evidence |
|---|---|---|
| CLAUDE_APP_ID | `com.anthropic.claude` (confirmed) | the user's iPhone app list via `devicectl` (Claude 1.260925.19), 2026-10-05; the ANCS `uid … app "…"` lines of row 5 (a), (b), (c) should show the same, _pending on-device_ |
| ACTIONS | _pending on-device_ (`<positive label / none>`, `<negative label / none>` per notification kind) | the details blocks of row 5: flags and labels |
| CONTENT | _pending on-device_ (title / subtitle / message per kind, shortened) | row 5 details blocks; message present while locked: _pending_ |
| PROMPTS | _pending on-device_ (pairing prompt text; notification-sharing prompt text; subscription before/after allowing: ok / refused (status)) | rows 1–2 |
| PREVIEWS | _pending on-device_ (Show Previews setting found; content arrived while locked) | row 5 |
| NO_APP_LINK | _pending on-device_ (Task 6 firmware: link kept with the app closed: yes / no; reconnect after a board reset without the app: yes / no (s); after an iPhone Bluetooth toggle: yes / no (s); via a Settings → Bluetooth tap: yes / no; board awake on battery with the link up: yes / no; battery drain with the app closed: % per hour) | "Without the translator app" rows 1–9 (Task 1 rows 7–8 were the preview) |

Bond mismatch: if the board's NVS is erased (full flash erase, new board) while the iPhone still holds the old
bond, encryption fails (`ble: link N: encryption failed (status …)`, no pairing prompt). Fix on the iPhone:
Settings → Bluetooth → (i) next to ESP-Translator → **Forget This Device**, then reopen the translator app to pair
again. (The reverse, iPhone forgot but board kept the bond, is handled by the board: REPEAT_PAIRING drops its old
key.)

After filling: if CLAUDE_APP_ID differs from `com.anthropic.claude`, change `ANCS_CLAUDE_APP_ID` in
`firmware/main/ancs.h`. If Claude notifications carry no positive / negative actions, note it here (Task 5 still
ships the buttons; they only appear when iOS offers actions).

## Without the translator app (Phase 4 Task 6)

Firmware (Task 6): on connect the board asks a **bonded** peer for encryption right away (silent re-encryption;
this is the one request of that connection, the app's subscribe does not ask again; an unbonded peer is still only
asked once the translator app subscribes). The scan response solicits the ANCS service (name shortened to
"ESP-Transla" there; the GAP name stays "ESP-Translator"). While only ANCS uses the iPhone link (the app is closed,
silent for 60 s, or not opened yet) the link runs at a relaxed pace (180–210 ms, latency 4); the translator app
taking the audio role switches it back to 30–45 ms. Log: `ble: link N: relaxed pace (rc R)` / `fast pace (rc R)`.

Deep-sleep rule: the ANCS link counts as a link only from `ancs: link N: Claude notifications from the iPhone on`
(both ANCS subscriptions done on an encrypted link) until that link drops (`ancs: iPhone notifications off`).
`main: iPhone notifications link up` / `down` in the log. While it is up the board does not deep-sleep on battery.

**Battery effect (estimate, not measured).** Before Task 6 an iPhone with the app closed let the board deep-sleep
3 min after the app left. Now, as long as a bonded iPhone with Share System Notifications stays in range, the board
stays awake: screen off, CPU at 80 MHz, BLE modem sleep, but no light sleep (power management keeps it off for the
mic I2S). Expect roughly the board's idle-awake draw, on the order of 25–40 mA, so a full 550 mAh battery lasts
very roughly 14–20 h instead of days in deep sleep. The relaxed link pace cuts the radio's share (about 5× fewer
connection events, latency 4) but the awake CPU dominates. Row 9 measures it. To save the battery when the board
is not needed (e.g. travelling): hold PWR to power off, or turn off Share System Notifications for the board in
Settings → Bluetooth → (i); the link then ends and the usual 3 min rule applies.

Verification (flash first; start with the translator app open and the board paired):

| # | Do | Record / expect |
|---|---|---|
| 1 | iPhone Settings → Bluetooth: is the board under My Devices as "ESP-Translator", Connected? (i): Share System Notifications on? | yes / no for each |
| 2 | Swipe the translator app away; wait 1–2 min | `ble: iPhone audio off` or `ble: iPhone app silent for 60 s — audio off`, then `ble: link N: relaxed pace (rc 0)`; no `disconnected`. A Claude notification still shows on the board |
| 3 | App still closed: press the board's RST; wait up to 2 min | iPhone reconnects by itself? `ble: connected`, `ble: link N: asking for encryption`, `encryption on`, `iPhone audio subscription restored from the bond: waiting for the app` (no `iPhone audio on`), `ancs: … ANCS at …`, `Claude notifications from the iPhone on`, `relaxed pace`, `main: iPhone notifications link up`. Seconds until reconnect. A Claude notification shows; the translator screen does not claim the iPhone is connected |
| 4 | App still closed: iPhone Bluetooth off, wait 10 s, on; wait up to 2 min | reconnect yes / no (seconds) |
| 5 | App still closed, board on battery (USB unplugged), link up: wait 4 min | no `entering deep sleep` |
| 6 | Open the translator app | `translator app active on the restored link` or `iPhone audio on`, then `fast pace`; translation works as before |
| 7 | If row 3 or 4 failed: Settings → Bluetooth → tap ESP-Translator | does that connect it (and start notifications) without the app? |
| 8 | iPhone out of range (or Bluetooth off) for 4 min, board on battery | `iPhone notifications off`, `main: iPhone notifications link down`, deep sleep ~3 min later |
| 9 | Battery drain: on battery, app closed, link up, screen off: note the battery % at the start and after 1 h | % per hour (100 % = 550 mAh) |

Outcome for the README: rows 2–4 pass → notifications work without the translator app. Row 2 passes, 3–4 fail,
row 7 works → after a board restart open the translator app once or tap the board in Settings → Bluetooth. Row 2
fails → notifications need the translator app running in the background (known limitation; no iOS change in this
phase).

## Log excerpts

_pending on-device_ — paste the relevant `ancs:` / `ble:` lines for rows 1, 2, 5 and 8. No other app's notification
content appears in the log by construction (only its bundle id); delete any line that shows more than that.
