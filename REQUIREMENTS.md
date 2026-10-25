# Requirements: Flutter app for iOS and Android, multi-language, special-word handling

Date: 2026-10-26. Status: draft for review (replaces the 2026-10-23 iOS-only draft).
Branch: `main` (= `claude-companion` at `3f23288`). The side branch `travel-a2dp` is not merged and is out of scope.

## Brief

No written brief exists. The brief is the user's own words from the conversation:

| ID | Brief line (user's words) | Meaning taken |
|---|---|---|
| B1 | "cái kia làm cho hơi thiếu chức năng do làm vội chúng ta sẽ build lại cho chuẩn chỉnh" | The app was built in a hurry; rebuild it properly instead of patching it |
| B2 | "multi language" | More than the one EN ↔ VI pair |
| B3 | "tối ưu lại các từ đặc biệt" | Handle names, brands, places, loanwords, slang and service phrases better |
| B4 | "ko giới hạn từ mobile iOS với android nữa mà chúng ta sẽ làm cả 2 app" | One product on iOS **and** Android |
| B5 | Chose "Flutter cho cả hai" | One Flutter codebase for both phones; the Swift app is replaced |
| B6 | Speech: "if else các thành phần hỗ trợ" | Use whatever the phone supports, best first, with fallbacks |
| B7 | Chose "Làm thẳng trong Flutter" | Multi-language is built into the Flutter app from the start; the board work comes first; the Swift app stays usable until the Flutter app catches up |
| B8 | Android: "Không, chỉ dịch" | No Claude relay in the Flutter app |

**Classification:** a project with a written design. It touches the board firmware (fonts, language label, board info), a new Flutter app with native code on each platform, and the measurement harness.

**Test devices:** iPhone (iOS 26, the current app's target) and a rooted Samsung Galaxy Note 9 (SM-N960F, Android 10, Magisk).

## Current state (verified)

- The Swift app (`ios/`, about 3,400 lines) hard-codes `en-US` ↔ `vi-VN` (`ConversationEngine.swift`), uses Apple `SpeechAnalyzer`, Apple Translation, `AVSpeechSynthesizer`, CoreBluetooth, and a tuned audio session (voice chat, ducking, silent keep-alive in the background).
- Pure logic with tests in `TranslatorCore` (44 `swift test` cases): `TurnAssembler`, `ConversationActivity`, `VoiceGate`, `SubtitleTranslator`, `VietnameseFixup`, `ADPCMDecoder`.
- BLE protocol: service `A7C00001-…`; `…0002` board audio (IMA ADPCM, a header per packet), `…0003` text (chunked, kind byte: subtitle, status, clock), `…0004` control; Claude service `A7C00010-…`.
- Board fonts cover Basic Latin, Latin-1 and the Vietnamese letters only. Flash 32 MB, app partition 6 MB.
- Flutter, Dart and the Android SDK are not installed on the Mac.

## Requirements

Priority: M = Must, S = Should, C = Could, W = Won't (this round).

### Platform (B4–B8)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| P1 | B4, B5 | One Flutter app (`app/`) that builds and runs on iOS 26 and on Android 10+ (minSdk 29) | `flutter build ios` and `flutter build apk` succeed; the app runs a full conversation on the iPhone and on the Note 9 | M | No |
| P2 | B1, B5 | Feature parity with the Swift app's translator: board link, their speech → Vietnamese in the earbuds, my Vietnamese → subtitles on the board, own-voice gate, turns, conversation on/off, board mic toggle, clear (with confirm), model download, the "Phụ đề" design | A parity checklist (one line per Swift feature) ticked on both phones | M | No |
| P3 | B6 | Speech recognition picks the best engine the phone has, per language: (1) the OS on-device recognizer; (2) bundled Whisper (whisper.cpp) when the OS has none for that language; (3) the OS online recognizer as a last resort, only with the user's consent and a visible "online" mark | A unit test of the selection with fake capabilities. On the Note 9 (no on-device OS recognizer), English and Vietnamese run through Whisper with the network off | M | No |
| P4 | B6 | Offline translation on both: Apple Translation on iOS, Google ML Kit on Android | Airplane mode after the downloads: a conversation works on both phones | M | No |
| P5 | B6 | Speech output in Vietnamese on both: `AVSpeechSynthesizer` on iOS, Android `TextToSpeech` (offline voice); if the Vietnamese voice is missing the app says so and links to the system download | On the Note 9 with no Vietnamese voice: the app shows the message; after installing it, translations are spoken | M | No |
| P6 | B1 | The app keeps working with the screen off and in the background while a conversation runs (iOS: background audio + Bluetooth; Android: a foreground service with a notification) | 10 minutes with the screen off on each phone: board speech is still spoken, subtitles still reach the board | M | No |
| P7 | B1 | The Bluetooth headset mic is used for my voice (AirPods on iOS; Bluetooth SCO on Android), with echo cancellation, and other apps' audio is ducked, not stopped, during a conversation | My speech through the earbuds produces subtitles on both phones; a YouTube video gets quieter and resumes | M | Android may only get SCO quality (8–16 kHz), see list below |
| P8 | B7 | The Swift app is kept, untouched apart from bug fixes, until P2 is ticked on the iPhone; then it is retired (code kept in git history) | — | M | No |
| P9 | B8 | No Claude relay in the Flutter app. The board's Claude service and the Mac app are not changed | The board still accepts the Swift app's relay while that app exists | M | No |

### Multi-language (B2)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| R1 | B2 | The user picks the other person's language. My side stays Vietnamese | Pick e.g. Japanese or French: their speech → Vietnamese in the earbuds; my Vietnamese → subtitles in that language on the board. Shown on both phones with the log | M | No |
| R2 | B2 | The list shows only languages that work fully on that phone: a recognizer by P3 **and** offline translation both ways with Vietnamese | A unit test with fake capabilities: a language missing either part is not listed | M | No |
| R3 | B2 | Per-language status and download (speech model, translation models, TTS voice): not installed / downloading / ready. Fully offline once ready | Airplane mode after the download: a conversation in the new language works. A language that is not ready cannot be started, and the app says why | M | No |
| R4 | B2 | The pick persists, and switching needs no restart | Relaunch: the last language is active. Switch during a session: the next phrase uses the new pair within 3 s, and nothing from the old pair is spoken afterwards | M | No |
| R5 | B2 | The board shows the active language (e.g. "EN", "日本語") | The label appears on the board within 1 s of a switch | M | No |
| R6 | B2 | The board renders every **Latin-script** language offered (incl. Latin Extended-A: Polish, Turkish, Czech…) | A firmware host test plus a photo: a sample sentence per Latin language has no missing glyphs | M | No |
| R7 | B2 | Characters the board cannot draw never vanish or show as boxes: the phone checks against the board's glyph set and sends a readable fallback | A unit test: such a sentence is sent with a transliteration or a marker. Never an empty subtitle | M | Simplified: transliteration only where a table exists |
| R8 | B2 | The board renders **Japanese, Korean, Chinese (Simplified)** and **Thai** | A photo of each at 22 and 36 px; the firmware still fits | S | Simplified: CJK limited to about 3,500 frequent characters |

### Special words (B3)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| R9 | B3 | Special-word rules are **per-language data files** (JSON assets) run by one Dart rule engine with today's features (whole word, clause start, context) | Every `VietnameseFixupTests` case, ported to Dart, passes with the VI rules as data | M | No |
| R10 | B3 | **Protected terms**: names, brands, places and glossary entries pass through translation unchanged (or as their fixed translation) | A corpus of ≥ 40 sentences per direction: each term verbatim or as its fixed translation in ≥ 95 % of outputs, per platform translator | M | No |
| R11 | B3 | **User glossary** in the app: add, edit, delete terms with an optional fixed translation per language. Stored on the phone only | A new term is used from the next phrase; it survives a relaunch | M | No |
| R12 | B3 | Recognition hints from the glossary where the engine accepts them (Apple `contextualStrings`, Whisper initial prompt) | A harness run: term recognition with hints ≥ without | S | Synthetic audio only |
| R13 | B3 | Today's VI rewrites (vocatives, service phrases) apply for **every** target language | The ported rewrite tests pass; two non-English targets show no literal vocative in a manual check | M | No |
| R14 | B3 | Starter rule packs for the common travel languages (at least the cross-language brand and loanword rules) | A rule file and tests for every listed language | S | Rules from synthetic measurements |

### Quality and build (B1)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| R15 | B1, B3 | Repeatable measurement per language and per engine: term accuracy (R10) and recognizer WER. Vietnamese on Apple stays within ±0.6 points of the README table | Harness output in a README table, for Apple, Android on-device (if any) and Whisper | M | Synthetic TTS voices |
| R16 | B1 | Nothing language-specific hard-coded: languages, engines, rules and fonts come from one language description. All pure logic is Dart with `flutter test` coverage | `grep` finds no locale literals outside the catalog. The ported Swift tests plus new tests pass | M | No |
| R17 | B1 | On device: no network in the translator path after downloads, except P3's opt-in online recognizer. The glossary never leaves the phone | Code review plus an airplane-mode run on both phones | M | No |
| R18 | B2 | Auto-detect the other person's language | — | C | Left out this round |
| R20 | B2 | My own language other than Vietnamese | — | W | Left out |
| R21 | B2 | The other person also hears the translation spoken | — | C | Left out this round |

## Faked / simplified / left out

| Item | Kind | Reason |
|---|---|---|
| P7 on Android | Simplified | Android routes a Bluetooth headset mic only over SCO (narrowband), and ducking/echo cancellation vary by vendor. The Note 9 result is what it is; measured, not promised to match AirPods |
| P3 Whisper latency | Simplified | Whisper works on whole utterances, not live partials. On the Note 9 the app shows "…" instead of live partials and translates after each pause. Model: `base` (multilingual, about 140 MB quantized) by default; `small` if the measured latency allows |
| R7 fallback | Simplified | A font per script is the real fix; transliteration covers most scripts until then |
| R8 CJK subset | Simplified | Full CJK at two sizes is tens of MB |
| R12, R14, R15 synthetic audio | Simplified | Before/after comparisons count, as in the current README |
| Claude relay in Flutter | Left out (B8) | Translation only. Retiring the Swift app (P8) ends the iPhone side of the relay; the Mac app and the board keep their code |
| R18 auto-detect | Left out (Could) | No language ID on the on-device engines; Whisper has it, but it is unreliable on short phrases |
| R20 any pair | Left out (Won't) | The gate, the vocative rules and the board UI assume my side is Vietnamese |
| R21 speak to them | Left out (Could) | A separate audio design (speaker while the headset holds the mic, echo into the board mic) |
| Cloud/LLM translation | Left out | Offline on device is a core promise |

## Open questions and assumptions

Each assumption holds until the user says otherwise.

1. **Flutter replaces the Swift app on iOS too** (B5). Assumption: yes, after parity (P8). Until then both exist.
2. **Online recognizer as the last fallback** (P3): opt-in per language and marked "online". Assumption: acceptable, because the user asked for fallbacks; it is off by default.
3. **Whisper model size and download**: bundled `base` makes the APK about 150 MB. Assumption: download it on first use instead, like the translation models (keeps the app small).
4. **Android minimum**: Android 10 (the Note 9). Assumption: no older devices.
5. **Languages**: whatever both platforms support offline with Vietnamese (likely en, zh, ja, ko, fr, de, es, it, pt, th, id, ru). The list may differ per phone (R2).
6. **Store release**: none planned; sideload the APK and run the iOS app from Xcode. Assumption: no Play Store or TestFlight work this round.
7. **Time budget**: none given; quality over speed ("chuẩn chỉnh").
8. **The board subtitle layout** does not change, apart from the language label and new fonts.
