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
- **Their phrase ends by itself**: when board packets pause, the English (or other) recognizer is fed 20 ms frames of digital silence (`BoardSilencePadder`, up to 3 s) and ends the phrase with its own endpointing. It is never `finalize`d: in `ios/Tools/latency-harness` any finalize turned 10 of 12 following utterances into punctuation (`,......`), while padding damaged none and gave the final phrase about 200 ms sooner.
- **Your phrase is finalized early**: the own-voice gate asks for `finalizeNow` after 0.4 s of non-speech and stays open until 0.8 s, so the Vietnamese final arrives about 0.42 s after you stop instead of 0.82 s (12/12 exact in the harness).
- **BLE**: 2M PHY, 15–30 ms connection interval, MTU 247. Audio uses notifications and text uses write-without-response. Each ADPCM packet is self-contained, so a lost packet costs only 20 ms of silence.

Measured on the board (Mac acting as the iPhone): about 245 packets in 5 s with 0 lost, and speech is about 30 dB above the noise floor.

## Buttons and lock screen

The board has two screens: the translator and the lock screen.

| Input | Unlocked (translator) | Locked |
|---|---|---|
| PWR ×1 | Lock | Lock face for 5 s (never unlocks) |
| PWR ×2 (×3 does the same) | — | Unlock → translator |
| PWR hold 3 s | Power off (battery) / screen off (USB) | same |
| BOOT | — | Unlock → translator; also wakes the board from deep sleep |
| Tap ×1 | normal UI | Lock face for 5 s: logo, clock, battery (`NN%`, `NN% · charging`, or `USB power` without a battery), a bouncing arrow and "Vuốt lên để mở khoá" |
| Swipe up (on the visible lock face) | — | Unlock: the face slides up and fades out |
| Tap ×2 | Screen off / on | Unlock (on the visible lock face) |

A swipe only counts when it starts on the lock face while it is shown (at least 60 px up, more up than
sideways); on the dark panel it at most does what a tap does (shows the face), so a swipe on the dark panel alone cannot unlock it.

Presses count as one series while each follows the previous release within about 0.5 s.
Locked means the panel is off and touch only answers the lock gestures; translation keeps running.
The clock is set only by the iPhone app (text kind 2), each time it connects and again when the phone's clock or
time zone changes (`--:--` until then).
While translating, the status line shows only the language label; the level ring around the screen brightens and
thickens with the voice.
The lock face shows the Live Translator mark (`assets/translator-mark.svg`: two half rings, blue for you and light for
them, around a small flame), drawn by `tools/gen_logo.py` (needs Pillow). `python3 tools/gen_logo.py` regenerates
`firmware/main/logo_img.c/.h` (RGB565) and the iOS app icon (`ios/Sources/Assets.xcassets`); `--preview out.png`
renders the board logo back.

## Power

| Where | What | Why |
|---|---|---|
| Board | Energy VAD (adaptive noise floor, 300 ms pre-roll, 400 ms hangover) | Silence is never transmitted: no radio time, no recognition work on the phone |
| Board | Screen off after 30 s without speech, subtitles or touch; a tap only wakes it | AMOLED power scales with lit pixels and brightness |
| Board | Lock (PWR ×1): panel off, the 5 s lock face is a static logo | No lit pixels, clock timer paused while locked |
| Board | Deep sleep on battery 3 min after the translator app's link goes away (or after boot without one); touch screen or BOOT wakes it. Never while linked, on USB power, or with the dev stay-on option (`CONFIG_TRANSLATOR_DEV_STAY_ON`) | Near-zero drain when you walk away |
| Board | CPU 160 MHz with DFS down to 80 MHz, BLE modem sleep, 30–45 ms connection interval | Fewer radio and CPU wake-ups |
| iPhone | Own-voice gate on the AirPods mic (`VoiceGate`): opens only on voiced frames well above the background and near your learned voice level | The Vietnamese recognizer runs only while *you* talk, not while the café does (gate: about 0.05 % of one core) |
| iPhone | Runs with the screen locked (`audio` + `bluetooth-central` background modes) | Keep the phone in your pocket, just wear the AirPods |
| iPhone | Holds the AirPods mic only during a conversation (`ConversationActivity`), see below | YouTube, TikTok and music keep playing; idle, the AirPods stay in music-quality A2DP |
| iPhone | Your phrase: `finalizeNow` 0.4 s into a pause. Theirs: silence padding while packets pause, at most 3 s | Gating input must not delay the last phrase; padding stops so silence costs no recognition work |

Measured end-to-end: a phrase is spoken in Vietnamese about 1 s after the English speaker stops (translation itself 24–27 ms).
Battery life has not been measured yet.

### Conversation on / off (sharing audio with other apps)

The app takes the AirPods mic only while a conversation is going on, so it does not block YouTube, TikTok or music:

- **Starts** when the board streams speech, when a translation has to be spoken, when you turn the board mic on, when you tap the status line in the app ("Idle — tap here or the board mic before you speak"), and when the app opens. Your own voice cannot start one: while idle the AirPods mic is off, so tap first. Once a conversation is on, your speech keeps it going.
- **During** a conversation the session is voice chat (`.playAndRecord`, AirPods mic over HFP) with `.mixWithOthers` + `.duckOthers`: a video in another app keeps playing, only quieter. The status line reads "Listening".
- **Ends** after 10 minutes with no speech from either side (long enough that the pauses of a normal conversation don't turn the mic off before your next sentence) (no board audio, own-voice gate closed, nothing being spoken). The mic engine stops and the session is deactivated with `.notifyOthersOnDeactivation`: other apps return to full volume and the AirPods to A2DP.
- **Idle**, "You say" does not listen: speak to the board (English), turn the board mic on, or tap the status line first. The app plays mixable silence (no mic, no ducking) so iOS keeps it running in the background: it still receives board audio, keeps the board link alive (keepalive every 20 s) and starts a conversation on English speech.
- **Mic unavailable** (iOS often refuses the mic to an app starting it from the background): the app stays idle, keeps the mixable silence playing (so it is not suspended and the board link stays alive) and still speaks translations of board speech through that playback session. It logs `conversation: mic start failed (…), staying idle` and retries automatically after 30 s; a tap retries at once.
- **Interruptions** (a call, Siri): the mic comes back only if a conversation was on and iOS says to resume; otherwise the conversation ends. While idle the app never takes the mic back.

### Vietnamese recognition (You → Them)

The Vietnamese dictation model ignores contextual strings and custom language models; what decides its accuracy is the audio it gets. Speech from people around you, heard before or after your own words, gets transcribed and translated as if you said it. So:

- **Own-voice gate** (`ios/Sources/Audio/VoiceGate.swift`). Your mouth is a few centimetres from the AirPods mics, so your voice is much louder there than anyone nearby. A 20 ms frame opens the gate only if it is at least 8 dB above the background (5th percentile of the last 3 s, so it follows café noise within seconds), periodic at a speech pitch (autocorrelation), and within 8 dB of your own level. Your level is learned per utterance (a median over your last five, weighted by length, so one shout does not shut out normal speech), forgotten when the audio route changes, and relearned when the mic gain drops (your voice and the background fall together). A sentence that trails off is kept as long as it continues without a gap. 300 ms pre-roll; the phrase is finalized after 0.4 s of non-speech and the gate closes at 0.8 s.
- **Fix-ups** (`ios/Sources/Translate/VietnameseFixup.swift`). Recurring loanword mishearings are corrected in the recognized text ("giữa lo" → Zalo, "hoa phay" → Wi-Fi, "C nga co" → Singapore, …). Before translation only, vocatives are dropped and a few service phrases and idioms are spelled out ("Em ơi, tính tiền!" → "Cho tôi thanh toán!" → "Let me pay!" instead of "Baby, charge!"). The "You say" panel shows what was recognized.
- **Turns** (`ios/Sources/App/TurnAssembler.swift`). A new subtitle screen starts only after a finalized phrase and a 2 s pause, never in the middle of a phrase that is still being recognized.

The word error rates of this gate on synthetic audio are in the table under [Measurements (R15)](#measurements-r15).

A bystander only 6 dB quieter than you, or babble 3 dB below you for seconds before you speak, still gets through: level cannot tell them apart. Until you have spoken for about a second in a session, the gate does not know your level yet. Whispering does not open the gate, by design: a whisper is unvoiced and far below your normal level, like a bystander. `swift test` in `ios/` runs the unit tests (gate, turns, fix-ups, subtitle translator) on the Mac.

## Repository layout

| Path | Contents |
|---|---|
| `firmware/` | ESP-IDF 5.5 firmware: `ble_link.c` (GATT server), `audio_in.c` (2 mics → ADPCM), `ui.c` (translator screen), `lock_ui.c` (lock face), `shell.c` + `modes.c` (lock and buttons), `clock.c`, `pmu.c`; host tests in `firmware/test/` |
| `sim/` | Desktop simulator of the board screen: the real `ui.c`, `lock_ui.c` and `modes.c` on LVGL + SDL2, with keys that fake the iPhone, the mic and a voice |
| `ios/` | The iPhone app (Swift, SwiftUI). The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). `Sources/Core` is the pure logic (`swift test`); `Tools/term-harness` and `Tools/vi-harness` are the measurement harnesses |
| `shared/` | Language data and the logic contract the iPhone app is tested against: `languages/*.json` (language packs, see `shared/languages/README.md`), `board_glyphs/*.txt` (code points of the board's CJK / Hangul / Thai fonts, also read by the firmware font tools), `copy/vi.json` (UI copy), `fixtures/` (test vectors, `shared/fixtures/README.md`; `fixtures/terms/` is the term-accuracy corpus) |
| `tools/` | `gen_logo.py`: draws the Live Translator mark into the lock-face logo (`firmware/main/logo_img.c`) and the iOS app icon; `fake_iphone.py`: a Mac stand-in for the iPhone over BLE |
| `fonts/` | Be Vietnam Pro SemiBold (OFL), converted to 22 px / 36 px LVGL bitmap fonts with full Vietnamese diacritics |

## BLE protocol (service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`)

The board has this one service. Text, control and the audio / control subscriptions need an **encrypted,
authenticated link with a 16-byte key from an LE Secure Connections bond** (numeric comparison; the board accepts
Secure Connections only, and drops a link that asks for passkey entry); board info stays open, so the app can read
it before pairing. The first access to a protected characteristic fails with ATT error 0x05 (Insufficient
Authentication) or 0x0F (Insufficient Encryption), and iOS shows its pairing dialog with 6 digits. The board shows
the same 6 digits full screen ("Ghép với iPhone", **Sai** / **Đúng**) over the translator and goes back to it
afterwards; the buttons ignore taps for the first second, an answer only counts for the code it was shown for, and
no answer in 30 s rejects. **The board must be unlocked to pair**: a request on a locked board is rejected with a
2 s "Mở khoá board để ghép" notice on the lock screen, and locking the board while a code is up rejects it. A
request is also rejected, with nothing on screen, while another link's code is up, or when it comes too often (one
per 10 s and five per 10 min per peer address, ten per 10 min overall). A code on screen holds deep sleep off for
at most its 30 s and only three times per idle period. A bond made by older firmware (Just Works or legacy pairing)
does not count: when such a link encrypts, the board asks for pairing once and streams nothing until the codes were
confirmed. A stale bond (the link fails its integrity check) is deleted. Simulator: `pair:482913` (`@2` for another
link), `pair:passkey`, `wait:1000`, then `pair:ok` / `pair:no`.

| Characteristic | Properties | Payload |
|---|---|---|
| `…0002` audio | notify (authenticated) | `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit, low nibble first]`, 16 kHz mono |
| `…0003` text | write / write-no-rsp (authenticated) | `[flags u8][kind u8][UTF-8]`. flags bit0 = first chunk, bit1 = last chunk. kind 0 = subtitle, 1 = status, 2 = time (`"<unix seconds> <UTC offset minutes>"`, ASCII, sent by the app on connect), 3 = language label |
| `…0004` control | read / write / notify (authenticated) | 1 byte: 0 = board mic off, 1 = on; the app writes `0xFF` every 20 s as a keepalive, and the board stops streaming audio after 60 s without any app write |
| `…0005` board info | read | `[protocol version u8][font sets u32 LE]`: which scripts the board can draw (latinVI 1, latinExtA 2, cjk 4, hangul 8, thai 16) |

**The iPhone app talks to one board only.** Trust on first use: the first board it finds is pinned once the
translator setup (board info, clock, label, mic) has finished on that link. From then on the app reconnects only
that board, by its CoreBluetooth identifier, and never connects another device advertising the board service.
With a new board, turn the old one off and pick **Quên board** in the settings menu: the pin is cleared and the app
looks for a board again.

## Getting started

> **Update the iOS app and the board firmware together.** The board drops the app's audio role after 60 s
> without the app's 20 s keepalive, and older firmware shows the time and label messages as subtitles.

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

### Board simulator (no board needed)

Runs the translator and lock screens on the Mac in a round 466×466 window, built from the same
`firmware/main` sources (LVGL 9.6 + SDL2; the firmware build downloads LVGL, else CMake fetches it).

```sh
brew install sdl2
cmake -S sim -B sim/build && cmake --build sim/build -j
sim/build/board-sim
```

The mouse is the finger (double-click = double tap, drag up on the lock face = swipe). Keys:
`C` iPhone connect/disconnect, `M` board mic, `T` next sample subtitle, `V` fake voice (level ring),
`K` lock (PWR ×1), `U` unlock (PWR ×2), `F` tap the lock screen, `P` screenshot (`board-N.bmp`).
Scripted, without a window: `sim/build/board-sim --headless --do "connect;mic:on;text:Hello!;level:80;shot:out.bmp"`
(all commands are listed at the top of `sim/sim.c`). BLE, audio and the PMU are faked.

### iPhone app screens without a board (demo mode)

Launching the app with `-demo <screen>` swaps in the fake engine and board, seeds the design's sample data and
opens that screen directly (`welcome`, `permissions`, `pair`, `language`, `live`, `lock`, `phoneonly`,
`boardlost`, `history`, `glossary`, `settings`, `sharing`). `ios/Tools/snap.sh [screen…]` builds for the iOS
Simulator (iPhone 17 Pro), launches each screen and saves `docs/ui-redesign/shots/<screen>.png`.

### iPhone app (Swift)

Requires Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an iPhone on iOS 26. No Simulator is used.

1. `cd ios && xcodegen generate`, then open `ESPTranslator.xcodeproj`. `project.yml` bundles `shared/languages`, `shared/board_glyphs` and `shared/copy` as resources.
2. Under Signing & Capabilities, set your own **Team** and a unique **Bundle Identifier**.
3. Connect the iPhone, enable Developer Mode, then Run.
4. On first launch, download the translation and recognition models and allow microphone access. After that it works offline.

Tests and builds (no iPhone, no Simulator):

```sh
cd ios && swift test        # Core logic, gate, turns, fix-ups, subtitle translator, shared fixtures
cd ios && xcodegen generate && xcodebuild -scheme ESPTranslator -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build    # Release build check
```

For an installable Release build, drop `CODE_SIGNING_ALLOWED=NO` and set your Team, or use Product > Archive in Xcode.

### Shared data: languages, UI copy, fixtures

**Add a language pack**

1. Copy the closest `shared/languages/<code>.json`. The schema is in `shared/fixtures/README.md` (sections `model.json` and `rules.json`); notes on the shipped packs are in `shared/languages/README.md`. Use a catalog code (`zh-Hans`, not `zh`). No locale literal belongs anywhere else in the code except the engine's mapping tables.
2. Add its term corpus `shared/fixtures/terms/<code>.tsv` (format and scoring rule: `shared/fixtures/terms/README.md`).
3. Extend the fixtures that list packs: `shared/fixtures/model.json` (`shippedPacks`) and `shared/fixtures/language_catalog.json`, plus cases in `rules.json` if the pack has rules.
4. Run the suites: `cd ios && swift test`; `cd ios/Tools/term-harness && swift test`.
5. Run the term harness for the new language (next section). `--write-packs` stores the best placeholder shape in the pack as `applePlaceholder`.

**Edit UI copy**: all user-visible text is Vietnamese and lives in `shared/copy/vi.json` (bundled through `ios/project.yml`). `CopyTests` checks that every key the Swift UI uses exists and every key in the file is used.

### Term harness and Vietnamese WER harness

Term accuracy (R10: names, brands and glossary entries survive translation in at least 95 % of outputs) is measured per language and placeholder shape. The corpus, the scoring rule and the case files are described in `shared/fixtures/terms/README.md`.

```sh
# Apple Translation, on the Mac (install the language pairs in System Settings > General > Language & Region > Translation Languages)
cd ios/Tools/term-harness
swift test
swift run term-harness --fake                         # smoke test, no translator
swift run term-harness [--lang en,ja] [--out results.md] [--write-packs]
```

Vietnamese recognition WER (own-voice gate and Apple `DictationTranscriber`), on the Mac with the iOS 26 frameworks:

```sh
cd ios/Tools/vi-harness && ./build.sh                  # builds vi-harness and vi-translate from the app's own sources
RT=1 ./vi-harness <new|legacy|none|oracle> out.tsv events.jsonl files...
```

The options (`GATE_*` environment variables, the `.region` files of the oracle gate) are described at the top of `ios/Tools/vi-harness/main.swift`.

## Measurements (R15)

R15: repeatable measurement per language. Vietnamese on Apple must stay within +/-0.6 points of the first table. Everything here uses synthetic audio (TTS voices) and a synthetic corpus: real speech will score worse, and the before/after differences are what count.

### Vietnamese recognition, Apple

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

### Term accuracy per language and placeholder shape (R10)

*To be filled by the device pass.* Each cell is "accuracy % - lost placeholders" over both directions (84 lines per language), as printed by the harness; the best shape per language is the one `--write-packs` stores. R10 target: at least 95 %.

| Language | `Zorvik{n}` | `[[{n}]]` | `TERM{n}` | `⟦{n}⟧` | `__{n}__` | Best shape |
|---|---:|---:|---:|---:|---:|---|
| en | | | | | | |
| fr | | | | | | |
| de | | | | | | |
| es | | | | | | |
| ja | | | | | | |
| ko | | | | | | |
| zh-Hans | | | | | | |
| th | | | | | | |

### Recognizer WER per language

*To be filled by the device pass.* Word error rate (character error rate for ja, zh-Hans and th) of Apple's on-device recognizer on the synthetic sentence set.

| Language | Apple on device |
|---|---:|
| vi | see the Vietnamese table above |
| en | |
| fr | |
| de | |
| es | |
| ja | |
| ko | |
| zh-Hans | |
| th | |

## Tuning

| Setting | File | Default | Effect |
|---|---|---|---|
| `turnGap` | `ios/Sources/App/TurnAssembler.swift` | 2 s | A pause longer than this (after a finalized phrase) starts a fresh subtitle screen |
| `VoiceGate.Config` | `ios/Sources/Audio/VoiceGate.swift` | 8 dB open margin, 8 dB own-voice margin, 0.3 s pre-roll, 0.4 s `finalizeAfter`, 0.8 s hangover | Lower margins pass quieter speech but also nearby voices. Check the `gate: open … background … voice …` log lines on the device. `finalizeAfter` sets how soon your phrase is finalized in a pause (at or past the hangover = on close) |
| `BoardSilencePadder.Config` | `ios/Sources/Engine/BoardSilencePadder.swift` | 20 ms frames, 0.1 s BLE grace, 3 s limit | Silence fed to their recognizer while board packets pause so it ends the phrase itself (no finalize) |
| `rate` | `ios/Sources/Engine/Speaker.swift` | 0.54 | Speaking rate of the Vietnamese voice |
| `idleTimeout` | `ios/Sources/App/ConversationActivity.swift` | 10 min | Silence after which the app releases the AirPods mic and other apps' audio returns to full volume |
| `MIC_GAIN_DB` | `firmware/main/audio_in.c` | 36 dB | Board microphone gain |
| `VAD_HANGOVER_FRAMES` | same | 40 (800 ms) | Lower = faster phrase end, but long pauses split sentences |
| `SCREEN_OFF_AFTER_MS` | `firmware/main/ui.c` | 30 s | Screen timeout |
| `SLEEP_RULE_IDLE_US` | `firmware/main/sleep_rule.h` | 3 min | Deep sleep timeout on battery without the translator app |

## Known limitations

- Using the AirPods microphone switches the AirPods to the call (HFP) profile. Speech output stays clear, but it is not music quality: during a conversation a video in another app also plays in call quality (ducked) until the conversation ends.
- The ESP32-S3 has BLE only (no Bluetooth Classic), so it cannot stream audio to the AirPods directly. The iPhone handles that leg.
- My side is always Vietnamese; the other language is picked from the packs in `shared/languages/`. Languages are offered only when the phone has a recognizer and offline translation both ways for them.
- The multi-language flow is not yet proven on the iPhone; the native brand spellings in the ja/ko/th packs have not been reviewed by native speakers.

## Not done / next (iOS code review, 2026-11-14)

Fixed in that review: ADPCM header index clamp, the four missing Swift fixture suites, a dead Vietnamese recognizer, zh-Hans locale mapping, board pinning ("Quên board"), and the glossary excluded from iCloud backup. Still open:

- A dead Vietnamese recognizer is noticed only when board audio arrives (or at the next start or mic-on). Catching it with no board audio needs a new engine event in the `VoiceEngine` contract.
- Board pinning is trust-on-first-use with no proof of identity: the pin stops a fake board that shows up after the real one is pinned, but not one present at the first connection. The real fix is a user-confirmed pairing (the board shows a code, the user confirms it on the phone, then a challenge-response with a key agreed at pairing), which needs firmware work.
- Switching to a language that needs a download leaves the old pair running: the board keeps getting subtitles in the old language while the screen asks to download the new one. Turn the mic off when entering `needsDownload` from a switch (R1, R5).
- Small race between the generation check and `engine.speak` (`ConversationController.say`): one phrase from the old pair could still be spoken right after a switch. Pass the generation into the engine (R4).
- The one-restart budget in `SessionMachine` never resets, so a second recognizer death hours later goes straight to `failed`. Reset it after a healthy period (P6).
- The failure screen shows the raw error code (`notReady`) under "Không khởi động được". Map error codes to Vietnamese copy.
- The label and subtitles share one replaceable BLE queue, so a subtitle can replace a label that has not been sent yet. The label's script is also chosen once at `running`, which is too early for a board that connects later with CJK fonts (R5).
- Per-buffer diagnostics on the audio path (`LiveTranscriber`: string keys, a lock and an RMS per buffer, a log line per result) while nothing reads the counters any more. Board audio is also decoded on the main actor.
- `Speaker` prints spoken text to stdout. Gate it behind debug builds.
- A glossary that was set aside after corruption, or that went read-only, is never shown to the user (`recoveredFromCorruption` is unused).
- Leftover: the mic usage text in `Info.plist` says "translate into English".
- Pack regexes are only checked for compiling. There is no adversarial-string time-bound test (ARCHITECTURE §7).
- The app builds in Swift language mode 5 with a fair amount of `@unchecked Sendable`. Move to Swift 6 mode.

## License

Code: MIT. Be Vietnam Pro font: SIL Open Font License 1.1 (`fonts/OFL.txt`).
