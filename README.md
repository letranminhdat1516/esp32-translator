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
You → Them   AirPods mic (echo-cancelled) ──► DictationTranscriber vi-VN ─partials─► Translation VI→EN ─BLE─► subtitles on AMOLED
Arbiter      While you speak (and for 1 s after), "Them → You" results are dropped so the board mic never translates your own voice
```

Latency design:
- **On device**: speech recognition (`SpeechAnalyzer`) and translation (`Translation` framework, `.lowLatency` on iOS 26.4+) run offline, so a weak cellular signal doesn't matter.
- **Models stay warm**: analyzers run for the whole session (`modelRetention: .processLifetime`), and the TTS voice is preloaded at launch.
- **Subtitles follow your speech**: volatile (partial) results are translated immediately. A latest-wins translator (`LatestWinsTranslator`) drops stale requests, so the screen always tracks the current sentence.
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
The session picker lists Claude sessions from Phase 2 on; for now it shows "No sessions yet".
The logo is `assets/cicca-dark.png`, converted to RGB565 by `tools/gen_logo.py` (needs Pillow;
`python3 tools/gen_logo.py` regenerates `firmware/main/logo_img.c/.h`, `--preview out.png` renders it back).

## Power

| Where | What | Why |
|---|---|---|
| Board | Energy VAD (adaptive noise floor, 300 ms pre-roll, 800 ms hangover) | Silence is never transmitted: no radio time, no recognition work on the phone |
| Board | Screen off after 30 s without speech, subtitles or touch; a tap only wakes it | AMOLED power scales with lit pixels and brightness |
| Board | Lock (PWR ×1): panel off, the 5 s lock face is a static logo | No lit pixels, clock timer paused while locked |
| Board | Deep sleep after 3 min without an iPhone; touch screen or BOOT wakes it | Near-zero drain when you walk away |
| Board | CPU 160 MHz with DFS down to 80 MHz, BLE modem sleep, 30–45 ms connection interval | Fewer radio and CPU wake-ups |
| iPhone | Same VAD on the AirPods mic; recognizers only receive speech | Neural recognition runs only while someone talks |
| iPhone | Runs with the screen locked (`audio` + `bluetooth-central` background modes) | Keep the phone in your pocket, just wear the AirPods |
| iPhone | Phrase finalization on pause (`SpeechAnalyzer.finalize`) | Gating input must not delay the last phrase |

Measured end-to-end: a phrase is spoken in Vietnamese about 1 s after the English speaker stops (translation itself 24–27 ms).
Battery life has not been measured yet.

## Repository layout

| Path | Contents |
|---|---|
| `firmware/` | ESP-IDF 5.5 firmware: `ble_link.c` (GATT server), `audio_in.c` (2 mics → ADPCM), `ui.c` (translator screen), `claude_ui.c`, `lock_ui.c`, `picker_ui.c`, `shell.c` + `modes.c` (modes, lock, buttons), `clock.c` |
| `tools/` | `gen_logo.py`: generates the lock-face logo (`firmware/main/logo_img.c`) from `assets/cicca-dark.png` |
| `mac/` | Swift package: `claude-board` daemon (Unix socket + CoreBluetooth) and `claude-board-hook` (Claude Code hook), plus install scripts |
| `ios/` | SwiftUI app. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| `fonts/` | Be Vietnam Pro SemiBold (OFL), converted to 22 px / 36 px LVGL bitmap fonts with full Vietnamese diacritics |

## BLE protocol (service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`)

| Characteristic | Properties | Payload |
|---|---|---|
| `…0002` audio | notify | `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit, low nibble first]`, 16 kHz mono |
| `…0003` text | write / write-no-rsp | `[flags u8][kind u8][UTF-8]`. flags bit0 = first chunk, bit1 = last chunk. kind 0 = subtitle, 1 = status, 2 = time (`"<unix seconds> <UTC offset minutes>"`, ASCII, sent by the app on connect) |
| `…0004` control | read / write / notify | 1 byte: 0 = board mic off, 1 = on |
| `…0010` Claude service | (service) | Claude companion mode, see below. Requires a bonded, encrypted link |
| `…0011` Claude request | write (with response), encrypted | Mac → board: permission request / status to display; kind 3 = time (id 0, same text as above, sent on connect) |
| `…0012` Claude answer | notify, encrypted | Board → Mac: Allow / Deny decision |

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

The board doubles as a physical approval button for Claude Code running on your Mac. When Claude asks for permission to run a tool, the board chimes and shows the tool and its command. Press Allow or Deny on the board. When Claude finishes a turn, the board plays a done chime and a "Claude finished: <project>" toast, and the Claude screen shows the last line of the reply. After you answer (or the request is cancelled, times out or the Mac disconnects), the board returns to the screen you were on (or goes dark again if it was locked).

Open the Claude screen with a **PWR double press**; **BOOT** goes back to the translator. A permission request takes over the screen in any mode, even when the board is locked. If you lock the board or switch away while a request is shown, it stays pending and comes back when you unlock (PWR ×1 or a double tap on the lock screen) or open the Claude screen (PWR ×2). The Mac gives up on a request after 90 s and cancels it on the board; if that cancel is lost, the board drops the request itself after 100 s ("Timed out").

```sh
bash mac/install.sh     # builds, installs to ~/.claude-board/bin, starts a launchd agent, adds Claude Code hooks
bash mac/uninstall.sh   # removes the agent, binaries and only the claude-board hook entries
```

The installer backs up `~/.claude/settings.json` (`settings.json.bak.<timestamp>`) before editing it. It adds three hooks: `PermissionRequest`, `Stop` and `Notification` (`idle_prompt`).

**Bluetooth permission.** The daemon carries an embedded Info.plist (bundle id `dev.cicca.claude-board`) so macOS can ask for Bluetooth access while it runs under launchd. On first launch macOS shows a Bluetooth permission prompt for `claude-board`: allow it. Because the binary is ad-hoc signed, macOS may ask again after you rebuild and reinstall. If you denied it, enable `claude-board` in System Settings > Privacy & Security > Bluetooth.

**First-time pairing.** The board's Claude service requires a bonded, encrypted link. The first time the daemon connects, macOS shows a Bluetooth pairing prompt. Accept it once.

**Re-pairing.** If the board is reflashed or its NVS is erased, the old bond is invalid. Run `defaults delete dev.cicca.claude-board boardIdentifier`, remove the board in macOS System Settings > Bluetooth, then restart the daemon and accept the pairing prompt again.

**Safety rules**
- Nothing is ever auto-approved. Only an explicit Allow on the board approves a request.
- If the daemon is not running, the board is off or not connected, or the request times out, the hook prints nothing and exits 0, so Claude Code shows its normal terminal prompt.

Daemon log: `~/.claude-board/daemon.log`.

## Tuning

| Setting | File | Default | Effect |
|---|---|---|---|
| `echoHold` | `ios/Sources/App/ConversationEngine.swift` | 1 s | How long board-mic results are ignored after you stop speaking. Raise it if the board still picks up your voice |
| `turnGap` | same | 2 s | A pause longer than this starts a fresh subtitle screen |
| `rate` | `ios/Sources/Speech/Speaker.swift` | 0.54 | Speaking rate of the Vietnamese voice |
| `MIC_GAIN_DB` | `firmware/main/audio_in.c` | 36 dB | Board microphone gain |
| `VAD_HANGOVER_FRAMES` | same | 40 (800 ms) | Lower = faster phrase end, but long pauses split sentences |
| `SCREEN_OFF_AFTER_MS` | `firmware/main/ui.c` | 30 s | Screen timeout |
| `SLEEP_AFTER_DISCONNECT_US` | `firmware/main/main.c` | 3 min | Deep sleep timeout without an iPhone |

## Known limitations

- Using the AirPods microphone switches the AirPods to the call (HFP) profile. Speech output stays clear, but it is not music quality.
- The ESP32-S3 has BLE only (no Bluetooth Classic), so it cannot stream audio to the AirPods directly. The iPhone handles that leg.
- Only one language pair (EN ↔ VI) is wired up. Other pairs are a matter of changing the locales in `ConversationEngine`.

## License

Code: MIT. Be Vietnam Pro font: SIL Open Font License 1.1 (`fonts/OFL.txt`).
