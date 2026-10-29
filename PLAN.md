# Native translator apps (Swift on iPhone, React Native on Android), multi-language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Every task is TDD: write the failing test, see it fail, implement, see it pass, commit.

**Goal:** Two phone apps that do what the Swift app does today plus a choice of the other person's language, data-driven special-word rules, protected terms and a user glossary: the existing Swift app on the iPhone, extended; a new React Native app on Android. The board is done (Phase 1 of the Flutter plan: fonts, label, board info, glyph lists).

**Architecture:** `ARCHITECTURE.md`, "Revision 2026-10-29". Pure logic exists twice (Swift `TranslatorCore`, TypeScript `android/src/core`) and is kept identical by **shared test fixtures** in `shared/fixtures/` that both suites must pass. Language packs and board glyph lists live in `shared/` and are loaded by both apps. Each platform wraps its own native engine (Swift: SpeechAnalyzer/Translation/AVSpeech; Kotlin: Whisper/ML Kit/TTS/foreground service) behind one `VoiceEngine` interface with a fake for tests.

**Reference implementation:** the Flutter app in `app/` (frozen: nobody edits it). Every port names the Dart file and test it ports. `app/` is deleted in P2.9.

**Tech Stack:** iOS 26, Swift 6 (language mode 5), SwiftUI, `swift test` on the Mac (no simulator), XcodeGen `ios/project.yml`. Android minSdk 29 / targetSdk 35, React Native (latest stable, New Architecture, Hermes, TypeScript strict), Jest, `react-native-ble-plx`, `@react-native-async-storage/async-storage`, Kotlin TurboModule, whisper.cpp via NDK 28.2 + CMake, ML Kit Translate, Android `TextToSpeech`. ESP-IDF 5.5 + LVGL 9.6 on the board (unchanged).

**Spec:** `REQUIREMENTS.md` (2026-10-26, amended 2026-10-29), `ARCHITECTURE.md`.

## Global Constraints

- Test devices: the Note 9 (SM-N960F, Android 10, serial `271c1de1761c7ece`), the only Android device, used by **one task at a time** (the task marked *phone: yes*); the user's iPhone (iOS 26) for the iOS parity run. **Never** start an iOS simulator or an Android emulator.
- Home language is always Vietnamese (`vi`); the other language is picked (R20 Won't).
- No network in the translator path except the opt-in online recognizer (marked "online") and model downloads (R17, P3).
- No locale literal (`"en-US"`, `"vi-VN"`, `"ja"`…) outside `shared/languages/*.json`, the catalog, and the native engine code-mapping tables (R16).
- BLE service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`, characteristics `…0002`–`…0005`, text kind 3 (label ≤ 32 bytes UTF-8), `…0005` `[version u8][fontSets u32 LE]` (FontSets bits latinVI 1, latinExtA 2, cjk 4, hangul 8, thai 16): as implemented by the flashed firmware and `app/lib/board/protocol.dart`.
- UI copy is Vietnamese, in the "Phụ đề" design: black ground, accent `#1E6FD9`, light accent `#4C8FE8`, text `#E3EAF0`, muted `#8A919C`, faint `#5E646D`, surface `#16171A` (`ios/Sources/UI/ContentView.swift`).
- The Swift app keeps working (EN↔VI) at every commit: the iPhone must never be without a usable app (P8). No Claude relay in the Android app (P9); the Swift relay stays as is.
- Glossary limits: 500 terms, 64 characters per term, 8 variants; control and bidi-override characters (U+202A–U+202E, U+2066–U+2069) rejected. Stored on the phone only.
- Whisper model `ggml-base-q5_1.bin`, SHA-256 `422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898`, 59,707,625 bytes, downloaded on first use, checked before loading.
- Commit messages start with the requirement IDs and the task id, e.g. `R9 R13: TS rule engine (T1b)`.

## Review Focus

1. **Board drops and reconnects mid-conversation** → on `ready` the app resends the clock (kind 2) and the label (kind 3); a stale write failing after a services reset must not wipe the new queue. Tests in T2 and S2.
2. **Language switch while translations are queued for speech** → nothing from the old pair is spoken after the switch (generations). Tests in P2.1 and P2.2.
3. **Glossary terms with regex characters or overlapping each other** (`C++`, `Q.1`, `Bến Thành` / `Chợ Bến Thành`) → matched literally, longest first, never double-masked; a lost or invented placeholder → `restore` fails and the fallback path runs. Fixture `terms.json`, tests in T1b and S1.
4. **Bluetooth headset lost mid-conversation on Android** → phone mic with the "mic điện thoại" chip (engine already does this; T4 forwards the event, T3 shows the chip).
5. **React Native app with the screen off** → the foreground service keeps the process, the JS thread keeps running, board audio keeps being spoken for 10 minutes. Proof in P2.3 (`adb logcat` with timestamps).

---

## Phase 0 — Shared data, skeletons, contracts

0.1, 0.2 and 0.4 are independent and run in parallel; 0.3 follows 0.2.

| Task | Requirements | Files | Proof |
|---|---|---|---|
| 0.1 Shared data + fixtures (from the Dart tests) | R9, R10, R16 | `shared/languages/*.json` and `shared/board_glyphs/*.txt` (copies of `app/assets/…`; a Dart test asserts byte equality), `shared/fixtures/*.json` (+ the two `.jsonl` turn fixtures moved from `app/test/fixtures`), `shared/fixtures/README.md` (schema of every file), the Dart tests in `app/test/**` rewritten to **read the fixtures** (this is the only allowed edit of `app/`) | `cd app && flutter test` stays green (≥ 414) with every ported-later test driven from a fixture: rules (every VietnameseFixup case + rule-engine cases), terms (mask/restore/repair), text pipeline, board text + translit + glyph subsets, glossary validation, catalog (fake capabilities → offered list, chain order), conversation activity, subtitle translator, ADPCM vectors, protocol (frameText, board info, label), session machine transitions |
| 0.2 React Native skeleton (phone: yes) | P1 | `android/` from `npx @react-native-community/cli@latest init LiveTranslator --directory android` (delete its `ios/`), `android/android/app/build.gradle` (minSdk 29, targetSdk 35, ndkVersion 28.2.13676358, abiFilters arm64-v8a + armeabi-v7a), package `vn.cicca.livetranslator`, TypeScript strict, Jest, deps `react-native-ble-plx`, `@react-native-async-storage/async-storage`; `android/README.md` (build/run/test commands), `.gitignore` | `npm test` passes; `npx react-native run-android` installs and shows the app on the Note 9 (screenshot in the report); `JAVA_HOME=/opt/homebrew/opt/openjdk@17` |
| 0.3 TypeScript contracts + fakes | R1–R4, P3–P7 | `android/src/core/model.ts` (port of `app/lib/core/model.dart`: FontSets, Script, Rule, Term, LanguagePack + JSON parsing with PackError, RecognizerKind, Capabilities, BoardInfo), `android/src/engine/VoiceEngine.ts` (interface = `app/lib/engine/voice_engine.dart` with `capabilities(home)`/`missing(pair)` async and typed `EngineError`), `android/src/engine/NativeVoiceEngine.ts` (TurboModule codegen spec: same calls; events via `EventEmitter`), `android/src/engine/FakeVoiceEngine.ts`, `android/src/engine/sessionMachine.ts` (= `session_machine.dart`), `android/src/board/protocol.ts` (= `protocol.dart`), `android/src/board/BoardLink.ts` + `FakeBoardLink.ts`, tests in `android/__tests__/` | `npm test`: model parses every `shared/languages/*.json`; protocol and session-machine fixtures pass; `npm run codegen` (or the Gradle codegen) generates the Kotlin spec without error; `npx tsc --noEmit` clean |
| 0.4 Swift contracts + fakes | R1–R4, P3–P7 | `ios/Sources/Core/Model.swift` (same types as 0.3, Codable from the same JSON), `ios/Sources/Core/VoiceEngine.swift` (protocol; async; `AsyncStream` events: mine, theirs, gate, ttsStart/End, audioSession, download), `ios/Sources/Core/FakeVoiceEngine.swift`, `ios/Sources/Core/SessionMachine.swift`, `ios/Sources/Core/BoardProtocol.swift` (frameText with kinds 0–3, board info decode, FontSets), `ios/Sources/Core/BoardLink.swift` (protocol over `ESPLink` + fake), `ios/Package.swift` (include `Core`), tests in `ios/Tests/TranslatorCoreTests/` | `cd ios && swift test` green (44 existing + new) reading `shared/languages` and `shared/fixtures` as test resources; `xcodegen` + `xcodebuild -scheme ESPTranslator -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` still builds (no simulator) |

## Phase 1 — Parallel tracks

Each track owns only its files; Phase 0 files are read-only (a needed change → NEEDS_CONTEXT to the lead). `app/` is read-only for everyone.

| Track | Task | Req. | Files owned | Proof |
|---|---|---|---|---|
| T1a TS core (A) | TurnAssembler, ConversationActivity, SubtitleTranslator, ADPCM | P2, R4 | `android/src/core/turnAssembler.ts`, `conversationActivity.ts`, `subtitleTranslator.ts`, `android/src/board/adpcm.ts`, tests | ports of `app/lib/core/turn_assembler.dart`, `conversation_activity.dart`, `subtitle_translator.dart`, `app/lib/board/adpcm.dart`; every fixture case passes; fake timers for the subtitle translator |
| T1b TS core (B) | RuleEngine, TermProtector, TextPipeline, BoardText + translit + glyph sets, Glossary, LanguageCatalog | R2, R7, R9–R11, R13, P3 | `android/src/core/ruleEngine.ts`, `termProtector.ts`, `textPipeline.ts`, `boardText.ts`, `translit.ts`, `boardGlyphs.ts`, `glossary.ts` (AsyncStorage, injectable store), `languageCatalog.ts`, tests | ports of the same-named Dart files; every fixture case passes; Review Focus 3; rules use `RegExp` with the `u` flag and engine-added word bounds (NFC via `String.prototype.normalize`); every bundled pattern < 50 ms on a 2 KB adversarial string |
| T2 RN BLE | BoardLink on react-native-ble-plx | P2, R5, R7 | `android/src/board/BleBoardLink.ts`, `BleAdapter.ts` (thin wrapper so tests mock it), tests | port of `app/lib/board/ble_board_link.dart` (+ `ble_adapter.dart`): scan/connect/discover, `…0005` read, subscribe audio+control, clock + label resend on ready, 20 s `0xFF` keepalive, mic-on at connect, services-reset re-setup, gen-guarded flush, backoff 0.5 s→10 s reset on ready/power-on; Review Focus 1; Android 12+ permission names documented |
| T3 RN UI | Conversation screen, language sheet, readiness/download, glossary editor, theme | P2, R1–R4, R11 | `android/src/ui/**`, `android/src/ui/theme.ts`, tests (react-test-renderer / `@testing-library/react-native`) | copy and layout from `app/lib/ui/*.dart` and `ios/Sources/UI/ContentView.swift`: listen/stop, clear-asks-first, partials, dimmed unclear lines, "online" and "mic điện thoại" chips, "Dừng nghe"; picks persist (AsyncStorage); missing items + Retry; glossary validation messages in Vietnamese. No phone: typecheck + tests only |
| T4 Kotlin engine → TurboModule (phone: yes) | Move the engine, bridge it, prove on the Note 9 | P3–P7, R3, R12 | `android/android/app/src/main/kotlin/vn/cicca/livetranslator/engine/**` (git mv from `app/android/app/src/main/kotlin/vn/cicca/livetranslator/engine/`, minus `EngineApi.g.kt` and `VoiceEnginePlugin.kt`), `…/VoiceEngineModule.kt` + package (TurboModule implementing the 0.3 spec; events through the emitter; `capabilities(home)`/`missing` off the main thread, home passed from JS: see the never-merged branch `worktree-agent-a2a8ea34f2a9a1746` for that change), `android/android/app/src/main/cpp/**` (whisper.cpp submodule path moves: update `.gitmodules`), manifest (mic, Bluetooth, foreground service microphone, notifications), `proguard-rules.pro`, JUnit tests (`src/test`) and instrumented tests (`src/androidTest`) moved, `android/tool/device_test.sh` (port of `app/tool/device_test.sh`) | JUnit 54+ green; `android/tool/device_test.sh` → OK on the Note 9 (Whisper model pushed from `/private/tmp/claude-501/-Users-cicca-Documents-personal/22463735-b558-4f26-ba35-5d5dd2fd572c/scratchpad/model/ggml-base-q5_1.bin` if missing); a temporary dev screen (`android/src/dev/EngineProbe.tsx`, kept) that calls `capabilities('vi')`, downloads what is missing for `en`, starts a session, and shows the `theirs`/`mine` events; logcat evidence |
| S1 Swift core port | RuleEngine (replaces VietnameseFixup), TermProtector, TextPipeline, BoardText + translit + glyph sets, Glossary, LanguageCatalog | R2, R7, R9–R11, R13, P3 | `ios/Sources/Core/RuleEngine.swift`, `TermProtector.swift`, `TextPipeline.swift`, `BoardText.swift`, `Translit.swift`, `BoardGlyphSets.swift`, `Glossary.swift` (JSON file in Application Support, injectable), `LanguageCatalog.swift`, tests; `VietnameseFixup.swift` becomes a thin wrapper or is removed with its callers updated | same fixtures as T1b, all green under `swift test`; `NSRegularExpression`/Swift `Regex` with engine-added bounds |
| S2 Swift engine + BLE | Multi-language engine behind the 0.4 protocol; ESPLink gains label, board info, services reset | P3–P7, R3, R5, R7, R12 | `ios/Sources/Engine/**` (git mv from `app/ios/Runner/Native/*` minus `EngineApi.g.swift`, `VoiceEngineHost.swift` reshaped into `AppleVoiceEngine: VoiceEngine`; Swift 6 strict concurrency warnings fixed, no pigeon), `ios/Sources/BLE/ESPLink.swift` (kind 3, `…0005`, `didModifyServices` → rediscover, gen-guarded writes), `ios/Sources/Speech/*`, `ios/Sources/Audio/*` (dedupe with the moved engine), `ios/project.yml`, `Info.plist`, a `swift test`-able host test target for the pure parts (like `app/ios/NativeTests`) | `swift test` green; `xcodebuild … generic/platform=iOS CODE_SIGNING_ALLOWED=NO build` 0 errors; the old `ConversationEngine` still compiles against the new pieces (EN↔VI unchanged) |
| S3 Swift UI | Language sheet, readiness/download view, glossary screen, label/online/phone-mic chips | R1–R4, R11 | `ios/Sources/UI/LanguageSheet.swift`, `ReadinessView.swift`, `GlossaryView.swift`, `ContentView.swift` (entry points only), a `UIState` observable with the fields from `app/lib/ui/conversation_state.dart`, SwiftUI previews | copy from `app/lib/ui/*.dart`; builds with the xcodebuild command above; previews compile; no runtime UI test required |

### Track notes

- **Fixtures are the contract.** A port that cannot pass a fixture case stops and reports NEEDS_CONTEXT; it never edits the fixture.
- **T1b/S1 placeholder shape:** per-pack field `placeholder` (default `"Zorvik{n}"`), longest term first, Latin case-insensitive, exact otherwise; restore returns nil/null on a lost or invented placeholder; `repair` is whole-word.
- **T4 JS ↔ Kotlin:** one TurboModule `VoiceEngine`; PCM from the board crosses as base64 `string` per packet (≤ 1 KB, ~50/s) or an `ArrayBuffer` if the RN version supports it in codegen; measure and note the choice.
- **S2** keeps the audio-session behaviour tuned in the Swift app (voice chat, ducking, silent keep-alive); `RecognizerPair` per language with the start token; warm-up before the session; mic failure surfaced as an error, never swallowed.
- **T3/S3 copy** is Vietnamese; English only for language names in their own script where the pack says so.

## Phase 2 — Integration, device runs, measurement

| Task | Req. | Files | Proof |
|---|---|---|---|
| P2.1 TS ConversationController + app wiring (phone: yes) | P1, P2, R1, R3–R5, R11, R17 | `android/src/engine/ConversationController.ts`, `android/App.tsx`, permissions flow, `BoardGlyphSets` loaded at startup | fake engine + fake board: full conversation; switch drops old generation (Review Focus 2); label on start/switch; pick persists; recognizer death → one restart then `failed`; translator throw → skipped / source kept; on the Note 9: real languages listed, English readiness + download, session starts (foreground notification), board optional |
| P2.2 Swift ConversationController + wiring | P2, R1, R3–R5, R11 | `ios/Sources/App/ConversationController.swift` (replaces the pair logic in `ConversationEngine.swift`), `ESPTranslatorApp.swift` | same tests as P2.1 under `swift test`; xcodebuild device build; run on the iPhone when available |
| P2.3 Android parity on the Note 9 (phone: yes) | P2, P3, P6, P7 | `docs/parity.md` | checklist ticked with Whisper offline (airplane mode), 10 min screen-off log (Review Focus 5) |
| P2.4 iOS parity on the iPhone | P2, P6, P8 | `docs/parity.md` | checklist ticked, 10 min screen-off |
| P2.5 Term harness (R10) per platform | R10 | `ios/Tools/term-harness` (Swift), `android/android/app/src/androidTest/.../TermHarnessTest.kt`, `shared/fixtures/terms/<lang>.tsv` (≥ 40 per direction) | table of term accuracy per placeholder shape; best shape written into each pack; ≥ 95 % or the gap reported |
| P2.6 WER per engine | R12, R15 | `ios/Tools/vi-harness` (unchanged), Android instrumented WER test | VI on Apple within ±0.6 of the README table; Whisper numbers added |
| P2.7 (S) Starter packs | R14 | `shared/languages/{ja,ko,zh-Hans,th,fr,de,es}.json`, fixture cases | both suites parse and pass them |
| P2.8 README | R15 | `README.md` | tables from P2.5/P2.6; run docs for both apps |
| P2.9 Delete the Flutter app | — | remove `app/` (keep `docs/PLAN-flutter-2026-10-26.md`); `.gitmodules` cleaned | both suites and both builds green without `app/` |

## Cut order if late

1. P2.7 starter packs beyond `en` (R14, S)
2. R12 recognition hints (S)
3. Online recognizer fallback on Android (keep Whisper)
4. P2.6 Whisper/Android WER tables (keep the VI regression check)
