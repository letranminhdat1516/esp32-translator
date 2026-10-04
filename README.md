# ESP32 Live Translator

Real-time, two-way English ↔ Vietnamese conversation translator built from a
Waveshare **ESP32-S3-Touch-AMOLED-1.75C** board, an **iPhone (iOS 26)** and **AirPods**.

- The other person speaks English → you hear Vietnamese privately in your AirPods.
- You answer in Vietnamese → they read live English subtitles on the round AMOLED screen.
- Everything runs **on device**: no cloud and no network needed after the first model download.
- No push-to-talk: both directions run continuously.

## Architecture

```
Them → You   Board mics ─ADPCM / BLE, 20 ms─► SpeechTranscriber en-US ─final phrase─► Translation EN→VI ─► vi-VN speech ─► AirPods
You → Them   AirPods mic (echo-cancelled) ─own-voice gate─► DictationTranscriber vi-VN ─phrases─► fix-ups ─► Translation VI→EN ─BLE─► subtitles on AMOLED
Arbiter      While you speak (and for 1 s after), "Them → You" results are dropped so the board mic never translates your own voice
```

Latency design:
- **On device**: speech recognition (`SpeechAnalyzer`) and translation (`Translation` framework, `.lowLatency` on iOS 26.4+) run offline, so a weak cellular signal doesn't matter.
- **Models stay warm**: analyzers run for the whole session (`modelRetention: .processLifetime`), and the TTS voice is preloaded at launch.
- **Subtitles follow your speech**: volatile (partial) results are translated immediately. `SubtitleTranslator` translates each finalized phrase once and keeps it, and re-translates only the current volatile phrase (latest wins), so requests stay one phrase long however long you talk.
- **Phrase-level speech**: each phrase is spoken as soon as the recognizer finalizes it (`fastResults`), without waiting for the end of the turn.
- **BLE**: 2M PHY, 15–30 ms connection interval, MTU 247. Audio uses notifications and text uses write-without-response. Each ADPCM packet is self-contained, so a lost packet costs only 20 ms of silence.

Measured on the board (Mac acting as the iPhone): about 245 packets in 5 s with 0 lost, and speech is about 30 dB above the noise floor.

## Buttons and lock screen

| Input | Unlocked | Locked |
|---|---|---|
| PWR ×1 | Lock | Unlock (back to the mode in use before locking) |
| PWR ×2 | Claude mode | Unlock → Claude mode |
| PWR ×3 (4 or more presses count as ×3) | Session picker | Unlock → Session picker |
| PWR hold 3 s | Power off (battery) / screen off (USB; on the Claude or picker screen a tap wakes it) | same |
| BOOT ×1 | Translator mode | Unlock → Translator mode |
| Tap ×1 | normal UI | Lock face for 5 s: logo, clock, battery (`NN%`, `NN% · charging`, or `USB power` without a battery) |
| Tap ×2 | Translator: screen off / on | Unlock |

A notification from the Claude iPhone app takes the screen over any mode, even when locked (see iPhone notifications). PWR ×1 then only closes it (the lock stays as it was); BOOT and PWR ×2/×3 close it and switch as usual. A Claude request from the Mac always wins over it.

Presses count as one series while each follows the previous release within about 0.5 s.
Locked means the panel is off and touch only answers the two lock gestures (except while a request is
shown: then neither tap does anything); translation and Claude notifications keep running. A Claude
permission request lights the panel and shows Allow/Deny (taps in the first 700 ms are ignored); once it is
answered or cancelled the board goes dark and stays locked. A request you leave on screen (PWR ×1 to lock,
BOOT, PWR ×3) stays pending: unlocking with PWR ×1 or a double tap brings it back on top, and PWR ×2 shows
it on the Claude screen, each time with Allow/Deny ignoring taps for the first 700 ms again.
The clock is set by the iPhone app and by the Mac daemon each time they connect, and again when the phone's
or the Mac's clock or time zone changes (`--:--` until then). Update the firmware and the iOS app together:
older firmware shows the app's time message (`"<seconds> <offset>"`) as a subtitle.
The session picker (PWR ×3) lists up to 6 Claude Code sessions from the Mac, "needs you" first, then the most
recent: a red dot needs you, yellow is working, green is idle, grey has ended (ended sessions leave after
10 min). "· new" marks a session that finished while another one was focused. Tap a row to focus it.
The logo is `assets/cicca-dark.png`, converted to RGB565 by `tools/gen_logo.py` (needs Pillow;
`python3 tools/gen_logo.py` regenerates `firmware/main/logo_img.c/.h`, `--preview out.png` renders it back).

## Power

| Where | What | Why |
|---|---|---|
| Board | Energy VAD (adaptive noise floor, 300 ms pre-roll, 800 ms hangover) | Silence is never transmitted: no radio time, no recognition work on the phone |
| Board | Screen off after 30 s without speech, subtitles or touch; a tap only wakes it | AMOLED power scales with lit pixels and brightness |
| Board | Lock (PWR ×1): panel off, the 5 s lock face is a static logo | No lit pixels, clock timer paused while locked |
| Board | The microphone and the voice characteristic are used only while a voice capture records (at most 30 s); the translator stream to the iPhone pauses during a capture | No extra radio or codec work when you are not speaking to Claude |
| Board | Deep sleep after 3 min without an iPhone link (the translator app or iPhone notifications); touch screen or BOOT wakes it. On battery, an iPhone link that only carries notifications (translator app closed, no Mac) keeps the board awake for at most 30 min after the later of the link coming up and the last Claude notice; then it sleeps anyway and notices that arrive meanwhile are missed (the iPhone keeps them). On USB it never sleeps | Near-zero drain when you walk away |
| Board | iPhone notifications: no polling, work only when the iPhone reports a notification; only the Claude app's are fetched; with the translator app closed the iPhone link relaxes to 180–210 ms (latency 4), but only 10 s after connecting and never on the Mac link | A notification costs a few radio packets; the link costs little while only notifications use it |
| Board | CPU 160 MHz with DFS down to 80 MHz, BLE modem sleep, 30–45 ms connection interval | Fewer radio and CPU wake-ups |
| iPhone | Own-voice gate on the AirPods mic (`VoiceGate`): opens only on voiced frames well above the background and near your learned voice level | The Vietnamese recognizer runs only while *you* talk, not while the café does (gate: about 0.05 % of one core) |
| iPhone | Runs with the screen locked (`audio` + `bluetooth-central` background modes) | Keep the phone in your pocket, just wear the AirPods |
| iPhone | Phrase finalization on pause (`SpeechAnalyzer.finalize`) | Gating input must not delay the last phrase |

Measured end-to-end: a phrase is spoken in Vietnamese about 1 s after the English speaker stops (translation itself 24–27 ms).
Battery life has not been measured yet.

### Vietnamese recognition (You → Them)

The Vietnamese dictation model ignores contextual strings and custom language models; what decides its accuracy is the audio it gets. Speech from people around you, heard before or after your own words, gets transcribed and translated as if you said it. So:

- **Own-voice gate** (`ios/Sources/Audio/VoiceGate.swift`). Your mouth is a few centimetres from the AirPods mics, so your voice is much louder there than anyone nearby. A 20 ms frame opens the gate only if it is at least 8 dB above the background (5th percentile of the last 3 s, so it follows café noise within seconds), periodic at a speech pitch (autocorrelation), and within 8 dB of your own level. Your level is learned per utterance (a median over your last five, weighted by length, so one shout does not shut out normal speech), forgotten when the audio route changes, and relearned when the mic gain drops (your voice and the background fall together). A sentence that trails off is kept as long as it continues without a gap. 300 ms pre-roll, 0.8 s hangover, then the phrase is finalized.
- **Fix-ups** (`ios/Sources/Translate/VietnameseFixup.swift`). Recurring loanword mishearings are corrected in the recognized text ("giữa lo" → Zalo, "hoa phay" → Wi-Fi, "C nga co" → Singapore, …). Before translation only, vocatives are dropped and a few service phrases and idioms are spelled out ("Em ơi, tính tiền!" → "Cho tôi thanh toán!" → "Let me pay!" instead of "Baby, charge!"). The "You say" panel shows what was recognized.
- **Turns** (`ios/Sources/App/TurnAssembler.swift`). A new subtitle screen starts only after a finalized phrase and a 2 s pause, never in the middle of a phrase that is still being recognized.

Word error rate of `DictationTranscriber` vi-VN on 25 synthetic sentences (one TTS voice, Mac with the iOS 26 frameworks, real-time feeding through the app's own code with `ios/Tools/vi-harness`). Real speech will score worse; the differences are what matter:

| Audio | Old energy gate | Own-voice gate | Cut at the true speech span |
|---|---:|---:|---:|
| Quiet room | 3.1 % | 3.1 % | |
| Telephone band (like the AirPods mic) | 1.2 % | 1.6 % | |
| Café babble 10 dB below your voice | 12.5 % | 1.9 % | 1.6 % |
| Telephone band + babble 10 dB | 9.4 % | 2.8 % | 3.1 % |
| Babble 3 dB below your voice | 23.8 % | 11.2 % | 6.6 % |
| Someone 12 dB quieter talking right before and after you | 117.8 % | 10.9 % | 6.9 % |
| 5 s of café babble (10 dB) before you start | 80.6 % | 7.8 % | 2.2 % |

(Run to run, the same audio varies by about ±0.6 points; one syllable is 0.3.)

A bystander only 6 dB quieter than you, or babble 3 dB below you for seconds before you speak, still gets through: level cannot tell them apart. Until you have spoken for about a second in a session, the gate does not know your level yet. Whispering does not open the gate, by design: a whisper is unvoiced and far below your normal level, like a bystander. `swift test` in `ios/` runs the unit tests (gate, turns, fix-ups, subtitle translator) on the Mac.

## Repository layout

| Path | Contents |
|---|---|
| `firmware/` | ESP-IDF 5.5 firmware: `ble_link.c` (GATT server), `audio_in.c` (2 mics → ADPCM), `ui.c` (translator screen), `claude_ui.c`, `question_ui.c` + `question.c` (question pages), `voice_ui.c` + `voice.c` (voice capture), `lock_ui.c`, `phone_ui.c` + `ancs_client.c` + `ancs.c` (iPhone notifications, ANCS), `picker_ui.c` + `sessions.c` (session picker), `shell.c` + `modes.c` (modes, lock, buttons), `clock.c` |
| `tools/` | `gen_logo.py`: generates the lock-face logo (`firmware/main/logo_img.c`) from `assets/cicca-dark.png` |
| `mac/` | Swift package: `claude-board` daemon (Unix socket, CoreBluetooth, on-device dictation, tmux typing) and `claude-board-hook` (Claude Code hook), the `cb` launcher (Claude Code inside tmux), plus install scripts |
| `ios/` | SwiftUI app. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| `fonts/` | Be Vietnam Pro SemiBold (OFL), converted to 22 px / 36 px LVGL bitmap fonts with full Vietnamese diacritics |

## BLE protocol (service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`)

| Characteristic | Properties | Payload |
|---|---|---|
| `…0002` audio | notify | `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit, low nibble first]`, 16 kHz mono |
| `…0003` text | write / write-no-rsp | `[flags u8][kind u8][UTF-8]`. flags bit0 = first chunk, bit1 = last chunk. kind 0 = subtitle, 1 = status, 2 = time (`"<unix seconds> <UTC offset minutes>"`, ASCII, sent by the app on connect) |
| `…0004` control | read / write / notify | 1 byte: 0 = board mic off, 1 = on |
| `…0010` Claude service | (service) | Claude companion mode, see below. Requires a bonded, encrypted link |
| `…0011` Claude request | write (with response), encrypted | Mac → board: `[kind u8][id u32 LE][UTF-8, at most 400 bytes]`, split into BLE writes `[flags u8][chunk]` (flags bit0 = first, bit1 = last). Kinds: 0 permission (id = request; `project\ntool\nsummary[\nrule]`, the rule line means Always allow is offered), 1 finished (fresh id; `project\nlast line`, focused session only), 2 cancel (id = request; also cancels a whole question set), 3 time (id 0; `"<unix seconds> <UTC offset minutes>"`, sent on connect), 4 session row (id = session handle, never 0; `<state> <since> <updated> <flags>\nproject\nlast line`; state `n` needs you / `w` working / `i` idle / `e` ended, times in Unix seconds, flags bit0 = focused, bit1 = unseen "new"), 5 session removed (id = handle), 6 sessions clear (id 0, first message of every full sync), 7 question page (id = request, shared by all pages; `<index> <count> <multi> <nopt>\nproject\nheader\nquestion\n(label\ndesc) × nopt`, up to 4 pages and 4 options), 8 voice (id = the board's voice id; `<p\|f\|x\|k>\ntext`: `p` live transcript, `f` final transcript (exactly what Send types, at most 300 bytes, empty = nothing heard), `x` error, `k` done; the Mac only sends them for the current capture). Session flags (kind 4) also have bit2 = voice (the session runs in a `cb` tmux pane the Mac can type into). See `firmware/main/claude_proto.h` |
| `…0012` Claude answer | notify, encrypted | Board → Mac, at most 10 bytes: `[id u32 LE][1\|2\|3]` allow / deny / always allow; `[id u32 LE][0x10][n u8][mask × n]` question answers (bit i of mask q = option i of question q); `[0 u32][0x20][mode u8]` board mode (0 other, 1 Claude screen, 2 picker); `[0 u32][0x21][handle u32 LE]` focus this session; `[voice u32][0x30][purpose u8][target u32 LE]` voice capture start (voice id never 0, chosen by the board; purpose low nibble 0 = command, target = session handle; 1 = Other answer, target = request id, question index in the high nibble; 2 = deny with reason, target = request id); `[voice u32][0x31]` audio complete, `[voice u32][0x32]` cancel, `[voice u32][0x33]` send the final transcript. Bit 7 of a question mask = the spoken Other answer |
| `…0013` Claude voice | notify, encrypted | Board → Mac, only during a voice capture: the board mic as `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit, low nibble first]`, 16 kHz mono, like `…0002`. The board offers voice only once the Mac has subscribed and the ATT MTU is at least 168, so a full frame fits in one notification |

On the iPhone's link the board is also a GATT client of Apple's Notification Center Service (ANCS,
`7905F431-B5CE-4E99-A40F-4B1E122D00D0`): it subscribes to Notification Source and Data Source and writes Get
Notification Attributes / Perform Notification Action to the Control Point (`firmware/main/ancs.h`). The scan response
solicits ANCS (name shortened to "ESP-Transla" there; the GAP name stays "ESP-Translator"). The board's own GATT table
is unchanged, except that the iPhone app now also writes `0xFF` to the control characteristic every 20 s as a
heartbeat (0..2 are the mic states): the board leaves the iPhone audio role after 60 s without any write from the
app, because a bonded iPhone keeps the link up for notifications after the app is gone.

## Getting started

### Firmware

Requires [ESP-IDF v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/).

```sh
. ~/esp/esp-idf/export.sh
cd firmware
idf.py -p /dev/cu.usbmodem1101 flash monitor
```

> **After pulling changes, delete `firmware/sdkconfig` before building.** ESP-IDF generates it once from
> `sdkconfig.defaults` and never refreshes it, so an old one keeps outdated settings (e.g. one BLE connection,
> no persistent bonds). The build stops with `Stale sdkconfig: delete firmware/sdkconfig and rebuild` when it detects this.

> Flashing replaces the factory demo. Back it up first if you want to keep it:
> `esptool -p <port> read-flash 0 0x2000000 backup.bin`. Restore it with `esptool write-flash 0 backup.bin`.
> `backup/` is git-ignored because a flash dump may contain Wi-Fi credentials.

### iOS app

Requires Xcode 26 and an iPhone on iOS 26.

1. `cd ios && xcodegen generate`, then open `ESPTranslator.xcodeproj`.
2. Under Signing & Capabilities, set your own **Team** and a unique **Bundle Identifier**.
3. Connect the iPhone, enable Developer Mode, then Run.
4. On first launch, download the English ↔ Vietnamese translation models and allow microphone access. After that it works offline.

## Claude companion mode

The board doubles as a physical approval button for Claude Code running on your Mac. When Claude asks for permission to run a tool, the board chimes and shows the tool and its command. Press Allow or Deny on the board (plus Always allow when offered, see below). When the focused session finishes a turn, the board plays a done chime and a "<project> · <last line>" toast; other sessions finish silently and show up as "Claude · N new" on the Claude screen and "· new" in the picker. After you answer (or the request is cancelled, times out or the Mac disconnects), the board returns to the screen you were on (or goes dark again if it was locked).

Open the Claude screen with a **PWR double press**; **BOOT** goes back to the translator. A permission request takes over the screen in any mode, even when the board is locked. If you lock the board or switch away while a request is shown, it stays pending and comes back when you unlock (PWR ×1 or a double tap on the lock screen) or open the Claude screen (PWR ×2). The Mac gives up on a request after 90 s and cancels it on the board; if that cancel is lost, the board drops the request itself after 100 s ("Timed out").

```sh
bash mac/install.sh     # builds, installs to ~/.claude-board/bin, starts a launchd agent, adds Claude Code hooks
bash mac/uninstall.sh   # removes the agent, binaries and only the claude-board hook entries
```

The installer backs up `~/.claude/settings.json` (`settings.json.bak.<timestamp>`) before editing it. It adds these hooks: `PermissionRequest` (synchronous: waits for the board, 100 s timeout) and, in the background (`async`), `Stop`, `Notification` (all types), `UserPromptSubmit`, `SessionStart` and `SessionEnd`. The hook passes `$TMUX_PANE` / `$TMUX` (and, inside tmux, its process ancestry, so the daemon can later check that the pane still runs that session) on to the daemon. The installer also installs `cb` (see Voice commands). Verified on Claude Code 2.1.289 (see `docs/superpowers/notes/2026-10-04-hook-spike.md`).

**Sessions.** The Claude screen shows the focused session: project, state with elapsed time ("Working · 12m"),
and the last line of Claude's reply; the title reads "Claude · N new" while other sessions have finished unseen.
A session is working after you submit a prompt, needs you on a permission request (or a permission / elicitation
notification), and is idle after a turn ends, on start, or on `idle_prompt`; `SessionEnd` ends it. Sessions that
never send `SessionEnd` (a crashed or killed terminal, or an interrupted turn, which sends no `Stop`) end on
their own after 2 h without events and leave the list 10 minutes later, like any ended session; when the focused
session leaves, the most recently updated remaining session becomes the focused one. Session updates reach the board only while it shows the Claude screen
or the picker (battery); requests, cancels and the focused session's "done" arrive in any mode.

**Questions.** When Claude asks a multiple-choice question (`AskUserQuestion`), the board shows one page per
question ("1/2 · project", header, question). Single choice: tap an option (radio), then Next. Several choices:
tick the boxes. Long-press an option to read its description; scroll the option list or question text when it
does not fit. Next / Send stay disabled until the page is answered; Send on the last page answers every question
at once, and Claude receives the chosen labels (several joined with ", "). Questions with more than 4
questions or 4 options stay in the terminal. While the Mac's voice link is up, every page ends with an "Other (speak)" row for a spoken free-text answer (see Voice commands).

**Always allow.** When Claude Code suggests a permission rule (an `addRules` suggestion) for the request, a
third button "Always allow" applies that rule (shown as "Rule: …"), so the same kind of call is not asked again.
Other suggestion types (e.g. `addDirectories`, `setMode`) do not get the button. Only allow rules are offered: an `addRules` suggestion whose
`behavior` is `deny` or `ask` (anything but `allow` or absent) never gets the button.

**Voice commands.** Say a command to Claude Code from the board. Start Claude with `cb` instead of `claude`
(same arguments); voice only ever types into a `cb` pane.

- `cb [claude arguments]` outside tmux runs Claude in a tmux session named `<folder name>-<6 hex of a hash of the full path>`
  (characters other than letters, digits, `_` and `-` become `_`), so two folders with the same name never share a session. If that
  session is already running, `cb` attaches to it (arguments are ignored, with a note). It refuses to attach to a
  session of that name that was not started by `cb`. Inside tmux it runs Claude in the current pane instead and marks
  that pane (the mark is cleared when Claude exits). Either way the pane gets the option `@claude_board=1`.
  Remote Control and everything else work as usual. Needs `tmux` (`brew install tmux`).
- `mac/install.sh` copies `cb` to `~/.claude-board/bin` and links it as `~/.local/bin/cb` when that folder exists
  (an existing `cb` there is left alone; otherwise it prints how to add the folder to `PATH`). `mac/uninstall.sh`
  removes the link only if it points to this install.

On the Claude screen tap **Speak**, say the command and stop talking. Recording ends 1.5 s after you stop, 5 s
after the tap if you said nothing (the board then shows "Didn't catch that"), when you tap Stop, or after 30 s.
The words appear live as you speak (the end of the sentence stays in view). Then the board shows exactly what will
be typed: **Send** types it into the session's tmux pane and presses Enter once, **Say again** records again,
**Cancel** drops it. Taps in the first 700 ms of each step are ignored. Transcription is Vietnamese by default
(`VoiceConfig.localeIdentifier` in `mac/Sources/ClaudeBoardCore/VoiceHub.swift`) and runs on the Mac with the
Speech framework's on-device dictation (`SpeechAnalyzer` + `DictationTranscriber`; the model downloads once). The
Mac's own microphone is not used: the audio comes from the board. A capture that sits unconfirmed for 120 s
times out ("Timed out — say it again").

Speak is hidden while the Mac voice link is down or a request is on screen, and greyed out with "Open with cb for
voice" when the focused session has no `cb` pane.

Before anything is typed (when you tap Speak, and again when you tap Send) the Mac checks that
- the pane exists, has not exited, and carries the `@claude_board` mark set by `cb`;
- the pane's process is the session's own: it is in the process chain the hook recorded, so the pane has not been
  taken over by another program;
- Claude is in the terminal foreground (not suspended with Ctrl-Z, which would leave a shell prompt that runs the
  text), and no other program it started holds the terminal (an editor opened with Ctrl-G, for example);
- the pane is not in a synchronized-panes window (`send-keys` would reach unverified panes), and not in copy mode;
- the session has not ended, and (at Send) is not waiting for an answer to a permission request or question in the
  terminal, because the text would answer it.

Otherwise the board says why ("Open with cb for voice", "The terminal is in copy mode — nothing sent", ...) and
nothing is typed. The text is cleaned before the board shows it, so what you read is exactly what is typed: control
characters and line separators become spaces, invisible format characters (zero-width spaces, BOM, soft hyphen...)
are removed, curly quotes become plain ones, whitespace collapses, leading `!`, `/` and `#` are stripped (Claude
Code's bash, slash-command and memory modes), and the text is cut to 300 bytes. The typing step refuses any text
that differs from that cleaned form. It uses `tmux send-keys -l` (literal) and one Enter, and is never retried (if
tmux times out the board warns that the text may have been typed).

- **Other (speak)**: on a question page the last row, "Other (speak)", records a spoken free-text answer. Say it and
  tap **Use**; the row then shows your words, selected (tap it to toggle it like an option; long-press to say it
  again), and Send on the last page answers as usual. Claude receives the spoken text as the answer.
- **Deny + why**: a permission request has a "Deny + why" button next to Allow / Deny. Say the reason and tap Send:
  the request is denied and Claude reads "The user denied this on the board and said: <reason>". Both appear only
  while the Mac voice link is up, and are cancelled if the request is answered in the terminal or times out.

**Speech permission.** The daemon asks macOS for Speech Recognition the first time it starts (its embedded
Info.plist carries the reason): allow it. If you denied it, the board says "Allow Speech Recognition for
claude-board in System Settings"; enable `claude-board` in System Settings → Privacy & Security → Speech Recognition.
Voice needs macOS 26 on the Mac. The daemon log says `voice ready (vi_VN)` or why voice is unavailable. To try
dictation without the board: `say -v Linh -o /tmp/vi.aiff "Xin chào" && ~/.claude-board/bin/claude-board --transcribe /tmp/vi.aiff`.
Voice was added to the Claude service, so a board with older firmware has no Speak (the daemon logs "board has no
voice characteristic"). After flashing, the board tells bonded Macs that its Claude service changed (GATT Service
Changed) and the daemon rediscovers it, so no re-pairing is needed.

**Bluetooth permission.** The daemon carries an embedded Info.plist (bundle id `dev.cicca.claude-board`) so macOS can ask for Bluetooth access while it runs under launchd. On first launch macOS shows a Bluetooth permission prompt for `claude-board`: allow it. Because the binary is ad-hoc signed, macOS may ask again (Bluetooth, and possibly Speech Recognition) after you rebuild and reinstall. If the prompt reappears after rebuilding or reinstalling the daemon, allow it again; if you denied it, enable `claude-board` in System Settings → Privacy & Security → Bluetooth.

**First-time pairing.** The board's Claude service requires a bonded, encrypted link. The first time the daemon connects, macOS shows a Bluetooth pairing prompt. Accept it once.

**Re-pairing.** If the board is reflashed or its NVS is erased, the old bond is invalid. Run `defaults delete dev.cicca.claude-board boardIdentifier`, remove the board in macOS System Settings > Bluetooth, then restart the daemon and accept the pairing prompt again.

**Safety rules**
- Nothing is ever auto-approved. Only an explicit Allow / Always allow tap approves a request, and only a Send tap answers a question; taps in the first 700 ms after anything appears, and taps on a dark panel, never count.
- Voice text is typed, stored as an answer or used as a deny reason only after an explicit Send / Use tap on the transcript shown, and typed only into a tmux pane the Mac verified for that session (see Voice commands).
- An iPhone notification's action runs only from an explicit tap on its button on the board (armed, lit panel, the notification on screen); nothing is done on the iPhone automatically, and only the Claude app's notifications are ever shown.
- If the daemon is not running, the board is off or not connected, or the request times out, the hook prints nothing and exits 0, so Claude Code shows its normal terminal prompt.

Voice commands were verified on hardware on 2026-10-05 with Claude Code 2.1.289: a spoken command typed into a `cb` pane, an empty capture, Other (speak) and Deny + why.

Daemon log: `~/.claude-board/daemon.log`.

## iPhone notifications (Claude app)

The board shows notifications from the Claude iPhone app (App Identifier `com.anthropic.claude`, confirmed on the
iPhone's app list): a short rising chime (none for silent notifications), then "iPhone · Claude" with the title,
subtitle and message, over any mode and even when the board is locked (the panel lights while it is shown). It
closes after 20 s (60 s when it has action buttons), when you tap **Close**, when you remove it on the iPhone, with
any board button (PWR ×1 only closes it; the lock stays as it was), or when a Claude request from the Mac arrives:
Mac requests always win, and while one is up an iPhone notification is not shown at all (the iPhone keeps it). One
notification at a time: a newer one replaces the one shown.

**Privacy.** Only `com.anthropic.claude` notifications are fetched and shown. For every other app the board reads
only the app identifier, to discard it: nothing from them is displayed, stored or logged. Leaving the screen
forgets the notification's text.

**Actions.** When iOS offers the notification's own actions, the board shows them as buttons (negative left,
positive right, with the iPhone's labels) and performs the action on the iPhone only when you tap one: the button
must be armed (700 ms after the notice appears or changes, or the panel lights), the panel lit, the link up and the
notification still on screen. The board then says "Done" or "Not done". **Close** only closes the board's screen;
the notification stays on the iPhone. Whether the Claude app's notifications carry actions has not been observed on
the iPhone yet; without them only Close is shown.

**Setup (once).** Open the translator app with the board on: iOS asks to pair with "ESP-Translator" (tap
**Pair**), and may ask to share notifications with it (allow). In Settings → Bluetooth → (i) next to ESP-Translator,
**Share System Notifications** must stay on. If you decline pairing the translator still works; there are just no
notifications. For the message text while the iPhone is locked, set Settings → Notifications → Claude → Show
Previews to **Always** (otherwise the notice has no text).

**Without the translator app.** A bonded iPhone is asked to encrypt right at connect (once per connection), so
notifications can resume after the app is closed or the board restarts. The board counts the notification link as
connected only when both ANCS subscriptions are on; with the app closed it relaxes the link pace after 10 s (never
on the Mac link) and, on battery, stays awake at most 30 min without the app or a Claude notice (see Power). A
restored link waits silently for the app: the translator screen does not claim the iPhone is connected. Whether iOS
reconnects the board by itself with the app closed has not been verified on hardware yet; if it does not, open the
translator app once or tap ESP-Translator in Settings → Bluetooth.

**Re-pairing.** If the board is reflashed with erased NVS, or iOS shows a pairing error: Settings → Bluetooth →
ESP-Translator → Forget This Device, then open the translator app and pair again.

Update the iOS app and the firmware together: the app's 20 s heartbeat is what keeps the board's iPhone audio role
alive (an older app is dropped after 60 s of silence).

Details and the on-device test plan: `docs/superpowers/notes/2026-10-05-ancs-discovery.md` (the hardware rows are
still pending).

## Tuning

| Setting | File | Default | Effect |
|---|---|---|---|
| `echoHold` | `ios/Sources/App/ConversationEngine.swift` | 1 s | How long board-mic results are ignored after you stop speaking. Raise it if the board still picks up your voice |
| `turnGap` | same | 2 s | A pause longer than this (after a finalized phrase) starts a fresh subtitle screen |
| `VoiceGate.Config` | `ios/Sources/Audio/VoiceGate.swift` | 8 dB open margin, 8 dB own-voice margin, 0.3 s pre-roll, 0.8 s hangover | Lower margins pass quieter speech but also nearby voices. Check the `gate: open … background … voice …` log lines on the device |
| `rate` | `ios/Sources/Speech/Speaker.swift` | 0.54 | Speaking rate of the Vietnamese voice |
| `MIC_GAIN_DB` | `firmware/main/audio_in.c` | 36 dB | Board microphone gain |
| `VAD_HANGOVER_FRAMES` | same | 40 (800 ms) | Lower = faster phrase end, but long pauses split sentences |
| `SCREEN_OFF_AFTER_MS` | `firmware/main/ui.c` | 30 s | Screen timeout |
| `SLEEP_AFTER_DISCONNECT_US` | `firmware/main/main.c` | 3 min | Deep sleep timeout without an iPhone |

## Known limitations

- iPhone notifications: one at a time (a newer one replaces the one shown); text only in the fonts' character set (other characters are dropped); notifications already on the iPhone when the board connects are not shown; notices that arrive while the board is in deep sleep are missed.
- Using the AirPods microphone switches the AirPods to the call (HFP) profile. Speech output stays clear, but it is not music quality.
- The ESP32-S3 has BLE only (no Bluetooth Classic), so it cannot stream audio to the AirPods directly. The iPhone handles that leg.
- Only one language pair (EN ↔ VI) is wired up. Other pairs are a matter of changing the locales in `ConversationEngine`.

## License

Code: MIT. Be Vietnam Pro font: SIL Open Font License 1.1 (`fonts/OFL.txt`).
