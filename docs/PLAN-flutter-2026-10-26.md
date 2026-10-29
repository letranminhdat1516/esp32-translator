# Flutter translator (iOS + Android), multi-language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Every task is TDD: write the failing test, see it fail, implement, see it pass, commit.

**Goal:** One Flutter app for iOS and Android that does what the Swift app does today, plus a choice of the other person's language, data-driven special-word rules, protected terms and a user glossary; the board learns new fonts, a language label and reports what it can draw.

**Architecture:** Dart owns all decisions and the board Bluetooth link (`app/lib`); a typed `pigeon` channel reaches one native `VoiceEngine` per platform (Swift in `app/ios/Runner/Native`, Kotlin in `app/android/.../native`) that does mic, gate, recognizers, translation and TTS. Everything in Phase 1 is written against the Phase 0 contracts and their fakes.

**Tech Stack:** Flutter 3.x / Dart 3, `pigeon`, `flutter_blue_plus`, `shared_preferences`, `path_provider`; iOS 26 (SpeechAnalyzer, Translation, AVFoundation); Android minSdk 29 (Kotlin, ML Kit Translate, TextToSpeech, SpeechRecognizer, whisper.cpp via NDK/CMake); ESP-IDF 5.5 + LVGL 9.6 on the board.

**Spec:** `REQUIREMENTS.md`, `ARCHITECTURE.md` (2026-10-26).

## Global Constraints

- iOS deployment target `26.0`; Android `minSdk 29`, `targetSdk 35`; test devices: the user's iPhone and the Note 9 (SM-N960F, Android 10, serial `271c1de1761c7ece`).
- Home language is always Vietnamese (`vi`); the other language is picked (R20 Won't).
- No network in the translator path except the opt-in online recognizer (marked "online" in the UI) and model downloads (R17, P3).
- No locale literal (`"en-US"`, `"vi-VN"`, `"ja"`…) in Dart or native code outside `assets/languages/*.json` and the catalog (R16).
- BLE service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A` and characteristics `…0002`–`…0004` stay byte-compatible with the current firmware; new: text kind 3 (label ≤ 32 bytes UTF-8), read characteristic `…0005` `[version u8][fontSets u32 LE]`.
- UI copy is Vietnamese, in the "Phụ đề" design: black ground, one accent `#1E6FD9`, light accent `#4C8FE8`, text `#E3EAF0`, muted `#8A919C`, faint `#5E646D`, surface `#16171A` (from `ios/Sources/UI/ContentView.swift`).
- The Swift app in `ios/` is frozen (bug fixes only) until the iOS parity checklist passes (P8). No Claude relay in Flutter (P9).
- Glossary limits: 500 terms, 64 characters per term, 8 variants; control and bidi-override characters (U+202A–U+202E, U+2066–U+2069) rejected.
- Whisper models downloaded on first use over HTTPS and checked by SHA-256 before loading.

## Review Focus

1. **Board drops and reconnects mid-conversation** → on `ready` again the app resends the clock (kind 2) and the language label (kind 3), and the next subtitle shows. Test in F1.
2. **Language switch while translations are queued for speech** → nothing from the old pair is spoken after the switch. Test in P2.1.
3. **Glossary terms with regex characters or overlapping each other** (`C++`, `Q.1`, `Bến Thành` and `Chợ Bến Thành`) → matched literally, longest first, never double-masked. Test in B6.
4. **Bluetooth headset not available or disconnected mid-conversation on Android** → the engine switches to the phone mic and sends `audioSession(routeChanged, phoneMic)`; the UI shows the "mic điện thoại" chip. Test in E1 (instrumented) and C1 (chip).
5. **Whisper output on silence or noise** ("Thank you for watching.", "Subtitles by…", repeated phrases) → dropped, never translated or spoken. Test in E6.

---

## Phase 0 — Contracts (sequential)

| Task | Requirements | Files | Proof (test/command) |
|---|---|---|---|
| 0.1 Toolchain + app skeleton | P1 | `app/` (from `flutter create`), `app/pubspec.yaml`, `app/android/app/build.gradle.kts`, `app/ios/Podfile`, `.gitignore` | `flutter doctor` no ✗ for Flutter/Android/Xcode; `cd app && flutter test` passes; `flutter build apk --debug` and `flutter build ios --no-codesign` succeed; `adb install` runs the template on the Note 9 |
| 0.2 Data model + language pack schema | R1, R2, R9, R16 | `app/lib/core/model.dart`, `app/assets/languages/vi.json`, `en.json`, `app/test/core/model_test.dart` | `flutter test test/core/model_test.dart` |
| 0.3 Native engine contract + fake | P3–P7, R3 | `app/pigeons/engine.dart`, generated `app/lib/engine/engine_api.g.dart`, `app/ios/Runner/Native/EngineApi.g.swift`, `app/android/app/src/main/kotlin/vn/cicca/translator/native/EngineApi.g.kt`, `app/lib/engine/fake_voice_engine.dart`, `app/test/engine/fake_voice_engine_test.dart` | `dart run pigeon --input pigeons/engine.dart` is clean; fake test passes |
| 0.4 Board protocol contract + fake | R5, R7, P2 | `app/lib/board/protocol.dart`, `app/lib/board/board_link.dart` (abstract), `app/lib/board/fake_board_link.dart`, `firmware/main/board_info.h`, `app/test/board/protocol_test.dart` | `flutter test test/board/` |
| 0.5 Session state machine | R3, R4 | `app/lib/engine/session_machine.dart`, `app/test/engine/session_machine_test.dart` | `flutter test test/engine/session_machine_test.dart` |

### Task 0.1: Toolchain + app skeleton

- [ ] Install: `brew install --cask flutter android-commandlinetools`, `brew install openjdk@17`; `sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.2.12479018" "cmake;3.22.1"`; `flutter config --android-sdk <sdk path>`; accept licences.
- [ ] `flutter create --org vn.cicca --project-name live_translator --platforms ios,android app`.
- [ ] Set `minSdk = 29`, `targetSdk = 35`, `ndkVersion = "27.2.12479018"`; iOS `platform :ios, '26.0'` and the Runner target's deployment target 26.0; bundle id `vn.cicca.livetranslator`.
- [ ] Add dependencies: `pigeon` (dev), `flutter_blue_plus`, `shared_preferences`, `path_provider`, `crypto`.
- [ ] `.gitignore`: `app/build/`, `app/.dart_tool/`, `app/ios/Pods/`, `app/android/.gradle/`, `app/android/local.properties`.
- [ ] Verify with the commands in the table; install on the Note 9 with `adb -s 271c1de1761c7ece install -r build/app/outputs/flutter-apk/app-debug.apk`.
- [ ] Commit `P1: Flutter app skeleton for iOS 26 and Android 10+`.

### Task 0.2: Data model + language pack schema

**Produces** (in `lib/core/model.dart`, immutable, `fromJson`/`toJson`):
- `enum Script { latin, cjk, hangul, thai, cyrillic, other }`
- `class FontSets` bit flags: `latinVI = 1`, `latinExtA = 2`, `cjk = 4`, `hangul = 8`, `thai = 16`; `bool covers(Script)`.
- `class Rule { String id, pattern, template; bool atClauseStart; String? context; }`
- `enum TermOrigin { builtIn, user }`; `class Term { String id, text; List<String> variants; Map<String,String> fixed; TermOrigin origin; }`
- `class LanguagePack { code, appleLocale, androidLocale, whisperCode, label, labelLatin; Script script; double? minConfidence; List<Rule> recognition, beforeTranslation; List<Term> terms; List<String> hints; }` and `static LanguagePack parse(String json)` that throws `PackError(field, reason)` on a missing field or an invalid regex.
- `enum RecognizerKind { osOnDevice, whisper, osOnline }`; `class Capabilities { Map<String, List<RecognizerKind>> recognizers; Set<String> translatable; bool vietnameseVoice; }`
- `class BoardInfo { int protocolVersion; FontSets fontSets; }`

**Tests:** `vi.json` and `en.json` parse; a pack missing `label` throws `PackError('label', …)`; a pack with pattern `(` throws `PackError('recognition[0].pattern', …)`; `FontSets(latinVI).covers(Script.cjk) == false`; JSON round trip equals.

`vi.json` in this task holds only the header fields (rules come in B5); `en.json` uses `appleLocale "en-US"`, `androidLocale "en-US"`, `whisperCode "en"`, `label "English"`, `labelLatin "EN"`, `minConfidence 0.4` (today's value).

Commit `R1 R2 R9 R16: language pack model and schema`.

### Task 0.3: Native engine contract + fake

**Produces** `pigeons/engine.dart` (`@HostApi() VoiceEngineApi`, `@FlutterApi() VoiceEngineEvents`), exactly the calls and events of ARCHITECTURE §5:
- Host: `CapabilitiesMsg capabilities()`, `List<MissingMsg> missing(PairMsg pair)`, `@async void download(MissingMsg item)`, `@async void start(PairMsg pair, String recognizerX, List<String> hints)`, `void stop()`, `void micOn(bool on)`, `void feedTheirAudio(Int16List pcm, int sampleRate)`, `@async String translate(String text, String from, String to)`, `void speak(String text, int id)`, `void stopSpeaking()`, `void setHints(List<String> hints)`, `void openTtsSettings()`.
- Events: `onMine(MineMsg)` (partial/final text, `startMs`, `endMs`), `onTheirs(TheirsMsg)` (text, confidence nullable, generation), `onGate(bool open)`, `onTtsStart(int id)`, `onTtsEnd(int id)`, `onAudioSession(AudioSessionMsg)` (`interrupted | resumed | routeChanged`, route `headset | phoneMic`), `onDownload(DownloadMsg)` (item, progress 0–1, `done`, error nullable).
- `MissingMsg.kind`: `speechModel | translation | ttsVoice`; `PairMsg`: `home`, `other`, `generation`.
- Dart wrapper `abstract class VoiceEngine` (same members, returning `Stream`s for events) and `FakeVoiceEngine implements VoiceEngine` with scriptable responses (`emitMine`, `emitTheirs`, `failNextTranslate`, `translations` map, recorded `spoken` list).

**Tests:** the fake records `speak` calls in order; `failNextTranslate` makes `translate` throw `EngineError.translateFailed`; emitted events arrive on the streams.

Commit `P3 P4 P5 P6 P7 R3: native VoiceEngine contract (pigeon) and fake`.

### Task 0.4: Board protocol contract + fake

**Produces** in `lib/board/protocol.dart`: the UUID constants; `enum TextKind { subtitle(0), status(1), time(2), label(3) }`; `List<Uint8List> frameText(String text, TextKind kind, int mtuPayload)` (flags bit0 first, bit1 last, same chunking as `ios/Sources/BLE/ESPLink.swift:75-95`); `BoardInfo? parseBoardInfo(Uint8List)` (null when shorter than 5 bytes); `String timeText(DateTime now)` = `"<unix seconds> <UTC offset minutes>"`.
`lib/board/board_link.dart`: `abstract class BoardLink { Stream<BoardState> state; Stream<Uint8List> audio; Stream<BoardControl> control; BoardInfo info; Future<void> sendText(String, TextKind); Future<void> setBoardMic(bool); }` with `enum BoardState { off, scanning, connecting, ready }`; `FakeBoardLink` records sent texts.
`firmware/main/board_info.h`: `#define BOARD_INFO_VERSION 1` and the same `FONTSET_*` bits as `FontSets`.

**Tests:** framing a 300-byte string at payload 180 gives 2 chunks with flags `0x01` and `0x02` and kind byte; a 10-byte string gives one chunk with flags `0x03`; frames equal the Swift fixture bytes for `"Xin chào"` kind 0 (write the fixture by running the Swift framing once and pasting the hex into the test); `parseBoardInfo([1, 3,0,0,0])` → version 1, `latinVI|latinExtA`; missing → `null` → callers treat as `FontSets(latinVI)`; a label over 32 bytes is cut at a UTF-8 boundary.

Commit `R5 R7: board protocol contract, board info header, fake link`.

### Task 0.5: Session state machine

**Produces** `sealed class SessionState` with the nine states of ARCHITECTURE §3 and `sealed class SessionEvent` (`catalogReady(saved, offered)`, `picked(code)`, `checked(missing)`, `downloadTapped`, `downloadDone`, `downloadFailed(error)`, `started`, `startFailed(reason)`, `recognizerDied`, `retry`); `SessionState next(SessionState s, SessionEvent e)` pure, plus `int generation` incremented on every `switching`.

**Tests:** one test per row of the §3 table (from-state, event, expected state); `running(X)` + `recognizerDied` → `preparing(X)` the first time and `failed` the second; switching increments the generation; an event that the table does not list for a state leaves the state unchanged.

Commit `R3 R4: session state machine`.

---

## Phase 1 — Parallel tracks

Each track owns only its files. Shared contracts from Phase 0 are read-only; a change to them goes back to the lead.

| Track | Task | Requirements | Files owned | Proof |
|---|---|---|---|---|
| A Board | A1 Latin Extended-A fonts + shared glyph set | R6, R7 | `firmware/main/font_vi_22.c`, `font_vi_36.c`, `firmware/main/glyphs.c/.h`, `firmware/main/ancs.c` (use `glyphs.h`), `firmware/tools/gen_fonts.sh`, `firmware/test/test_glyphs.c` | `cc … test_glyphs.c ../main/glyphs.c && /tmp/test_glyphs`; `idf.py build` 0 warnings |
| A | A2 Language label (text kind 3) | R5 | `firmware/main/ble_link.c` (text handler), `firmware/main/ui.c/ui_set_label`, `firmware/main/app.h`, `sim/sim.c` (`label:` command) | sim: `--headless --do "connect;label:日本語;shot:l.bmp"` shows "Live translation · 日本語" in the status line; an old phone app's unknown kind still lands as subtitle |
| A | A3 Board info characteristic `…0005` | R7 | `firmware/main/ble_link.c` (GATT table), `firmware/test/claude_ble_test.py` → new `firmware/test/board_info_ble.py` | `python3 firmware/test/board_info_ble.py` reads `01 03 00 00 00` from the flashed board |
| A | A4 (S) Font partition + CJK/Hangul/Thai | R8 | `firmware/partitions.csv`, `firmware/main/font_store.c/.h`, `firmware/tools/gen_fonts.sh`, `firmware/fonts/*.bin` | photo per script at 22/36 px; `idf.py size` app < 6 MB; board info reports the new bits |
| B Dart core | B1 TurnAssembler port | P2 | `app/lib/core/turn_assembler.dart`, `app/test/core/turn_assembler_test.dart` (+ `test/fixtures/*.jsonl` copied from `ios/Tests/TranslatorCoreTests/Fixtures`) | every case of `TurnAssemblerTests.swift` passes in Dart |
| B | B2 ConversationActivity port | P2 | `app/lib/core/conversation_activity.dart`, test | every case of `ConversationActivityTests.swift` (incl. `userStop`) |
| B | B3 SubtitleTranslator port | P2, R4 | `app/lib/core/subtitle_translator.dart`, test | every case of `SubtitleTranslatorTests.swift` |
| B | B4 ADPCM decoder port | P2 | `app/lib/board/adpcm.dart`, test | the Swift decoder's vectors; a lost packet inserts matching silence (≤ 10 packets) |
| B | B5 RuleEngine + `vi.json` rules | R9, R13 | `app/lib/core/rule_engine.dart`, `app/assets/languages/vi.json` (rules), test | every case of `VietnameseFixupTests.swift`; every bundled pattern finishes on a 2 KB adversarial string in < 50 ms |
| B | B6 TermProtector | R10, R11 | `app/lib/core/term_protector.dart`, test | mask/restore tests incl. Review Focus 3; lost placeholder → `restore` returns `null` |
| B | B7 TextPipeline | R9, R10, R13 | `app/lib/core/text_pipeline.dart`, test | `prepare`/`finish` both directions with the fake translator; vocatives dropped for `ja` and `fr` targets |
| B | B8 BoardText | R7 | `app/lib/core/board_text.dart`, `app/lib/core/translit.dart`, test | Cyrillic/Greek transliterated for `latinVI`; CJK without `cjk` font → transliteration if available else `·` per word; never empty; same code points as `glyphs.c` (shared table test) |
| B | B9 Glossary store | R11, R17 | `app/lib/core/glossary.dart`, test | limits and rejections; corrupt file renamed `glossary.corrupt-<date>.json`; change stream fires |
| B | B10 LanguageCatalog + recognizer selection | R2, P3 | `app/lib/core/language_catalog.dart`, test | fake capabilities: language missing translation is not offered; chain order per platform as ARCHITECTURE §5; `osOnline` only when consent stored |
| F BLE | F1 BoardLink on flutter_blue_plus | P2, R5 | `app/lib/board/ble_board_link.dart`, `app/test/board/ble_board_link_test.dart` (against a mocked `flutter_blue_plus` adapter) | Review Focus 1: reconnect resends time + label; label only sent when `…0005` exists |
| C UI | C1 Conversation screen ("Phụ đề") | P2 | `app/lib/ui/conversation_screen.dart`, `app/lib/ui/theme.dart`, `app/test/ui/conversation_screen_test.dart` + goldens | widget tests: listen/stop button, clear asks first, partials, unclear lines dimmed, "online" and "mic điện thoại" chips; goldens at 393×852 |
| C | C2 Language picker + readiness/download | R1–R4 | `app/lib/ui/language_sheet.dart`, `app/lib/ui/readiness_view.dart`, tests | picks persist; missing items listed; download error shows Retry |
| C | C3 Glossary editor | R11 | `app/lib/ui/glossary_screen.dart`, test | add/edit/delete with validation messages in Vietnamese |
| D iOS native | D1 Move the Swift engine into the plugin | P2, P4–P7 | `app/ios/Runner/Native/*.swift` (from `ios/Sources/Audio`, `Speech`, `Translate/Translator.swift`, audio-session code of `ConversationEngine.swift`), `app/ios/Runner/AppDelegate.swift`, `Info.plist` (mic, speech, Bluetooth, background `audio` + `bluetooth-central`) | `xcodebuild test` on `RunnerTests` with `VoiceGate` fixture tests; Flutter app on the iPhone speaks a board phrase |
| D | D2 Capabilities, downloads, hints on iOS | R2, R3, R12 | `app/ios/Runner/Native/Capabilities.swift`, `Downloads.swift` | on device: `capabilities()` lists the OS languages; Translation download sheet; a cancelled download emits `onDownload(error)` |
| E Android native | E1 Foreground service + audio routing | P6, P7 | `app/android/.../native/VoiceService.kt`, `AudioRouter.kt`, manifest permissions | instrumented test on the Note 9: SCO headset → `headset`; headset off → `routeChanged(phoneMic)` (Review Focus 4); 10 min screen-off log |
| E | E2 VoiceGate port (Kotlin) | P2, P7 | `.../native/VoiceGate.kt`, `app/android/app/src/test/.../VoiceGateTest.kt` + the Swift WAV fixtures | JUnit results equal the Swift `VoiceGateTests` expectations |
| E | E3 ML Kit translation + downloads | P4, R3 | `.../native/MlKitTranslator.kt`, `Downloads.kt` | instrumented: en↔vi offline in airplane mode after download |
| E | E4 TextToSpeech | P5 | `.../native/Speaker.kt` | missing Vietnamese voice → `missing()` includes `ttsVoice`; `openTtsSettings()` opens the system screen |
| E | E5 OS recognizers (on-device API 33+, online) | P3 | `.../native/OsRecognizer.kt` | on the Note 9: on-device reported unavailable; online works only after consent |
| E | E6 whisper.cpp recognizer | P3, R12 | `app/android/app/src/main/cpp/` (whisper.cpp as a git submodule pinned to a release tag, `CMakeLists.txt`, `whisper_jni.cpp`), `.../native/WhisperRecognizer.kt`, `ModelStore.kt` | JUnit/instrumented: SHA-256 mismatch refuses the model; real-time factor logged on the Note 9; hallucination filter (Review Focus 5) drops the listed phrases and > 2 repeats |

### Track notes (decisions a builder can't make alone)

- **A1** ranges: today's `-r` list plus `0x100-0x17F` (Latin Extended-A) and `0x2019` already present; same font (`BeVietnamPro-SemiBold.ttf`), sizes 22 and 36, `--bpp 4`. `glyphs.c` exports `bool glyph_ok(uint32_t cp, uint32_t font_sets)` driven by a range table that `gen_fonts.sh` writes from the same list; B8 mirrors that table and has a test that compares it with `glyphs.c` (parse the C table).
- **A2** status line: `"<current status> · <label>"`; the label persists across reconnects until a new one arrives; empty label clears it.
- **B5** `vi.json` rules are a 1:1 transcription of `VietnameseFixup.swift`'s rules with `id`s; Dart `RegExp(unicode: true)`; whole-word bounds are added by the engine, not written in the patterns.
- **B6** token shape is a per-pack field `placeholder` (default `"Zorvik{n}"`, n = 1…); longest term first; a term inside a longer matched term is not masked again; matching is case-insensitive for Latin, exact otherwise.
- **C1** port layout and copy 1:1 from `ios/Sources/UI/ContentView.swift`, including "Dừng nghe" and the clear confirmation.
- **D1** moves code with `git mv` where whole files move, so history follows; the Swift app in `ios/` keeps its own copies until P8.
- **E6** Whisper default model `ggml-base-q5_1.bin`; the URL and SHA-256 live in `ModelStore.kt`; utterances cut by the gate (mine) or by board silence (theirs); no partials (emit only `final`); drop when `no_speech_prob > 0.6`.

## Phase 2 — Integration + full data run

| Task | Requirements | Files | Proof |
|---|---|---|---|
| P2.1 ConversationController | P2, R1, R4, R5 | `app/lib/engine/conversation_controller.dart`, test | fake engine + fake board: a full conversation; switch drops old-generation phrases and nothing old is spoken (Review Focus 2); label sent on start/switch |
| P2.2 iOS end to end + parity checklist | P2, P6, P8 | `docs/parity.md` | every Swift feature ticked on the iPhone, 10 min screen-off |
| P2.3 Android end to end on the Note 9 | P2, P3, P6, P7 | `docs/parity.md` | same checklist on the Note 9 with Whisper offline |
| P2.4 D2 spike: placeholder shape per pair and platform | R10 | `app/tool/harness/terms.dart`, `app/test/fixtures/terms/<lang>.tsv` (≥ 40 per direction) | table of term accuracy per shape; best shape written into each pack; ≥ 95 % or the gap reported |
| P2.5 Recognition WER per engine | R12, R15 | `app/tool/harness/wer.dart`, `ios/Tools/vi-harness` (unchanged) | VI on Apple within ±0.6 of the README table; Whisper and Android numbers added |
| P2.6 (S) Starter packs | R14 | `app/assets/languages/{ja,ko,zh-Hans,th,fr,de,es}.json`, tests | each pack parses, has tests for its rules |
| P2.7 README tables + run docs | R15 | `README.md` | tables filled from P2.4/P2.5 |
| P2.8 Retire the Swift app (after the user's go) | P8 | delete `ios/` (except `Tools/vi-harness` moved to `tools/`) | user approval in chat first |

## Cut order if late

No time budget is set; if one appears, cut in this order (last cut first to go):
1. P2.6 starter packs beyond `en` (R14, S)
2. A4 CJK/Hangul/Thai fonts on the board (R8, S) — R7 transliteration stays
3. R12 recognition hints (S)
4. E5 online recognizer fallback (keep Whisper)
5. P2.5 Whisper/Android WER tables (keep the VI regression check)
6. P2.8 retiring the Swift app (it can stay frozen)
