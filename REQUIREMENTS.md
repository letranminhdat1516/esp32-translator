# Requirements: ESP32 board + iPhone live translator, multi-language, special-word handling

Date: 2026-10-26, amended 2026-10-29 and 2026-11-15. Status: approved.

**Scope (2026-11-15, user decision):** the project is only the translator: the ESP32 board and the Swift iPhone
app. The other phone apps and the companion features built earlier were removed (git history keeps them), and
the requirements that only concerned them are dropped below.

## Brief

No written brief exists. The brief is the user's own words from the conversation:

| ID | Brief line (user's words) | Meaning taken |
|---|---|---|
| B1 | "cái kia làm cho hơi thiếu chức năng do làm vội chúng ta sẽ build lại cho chuẩn chỉnh" | The app was built in a hurry; rebuild it properly instead of patching it |
| B2 | "multi language" | More than the one EN ↔ VI pair |
| B3 | "tối ưu lại các từ đặc biệt" | Handle names, brands, places, loanwords, slang and service phrases better |
| B5 | "apple giữ swift cx đc" (2026-10-29) | The Swift app on the iPhone is kept and extended |
| B6 | Speech: "if else các thành phần hỗ trợ" | Use whatever the phone supports, best first, with fallbacks |
| B7 | The board work comes first | Fonts, language label and board info on the board before the app uses them |

**Test devices:** the board (Waveshare ESP32-S3-Touch-AMOLED-1.75C) and an iPhone on iOS 26.

## Requirements

Priority: M = Must, S = Should, C = Could, W = Won't (this round).

### Platform

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| P1 | B5 | The Swift app (`ios/`) on iOS 26 | `xcodebuild` (device, no code signing) succeeds; the app runs a full conversation on the iPhone | M | No |
| P2 | B1 | Translator features: board link, their speech → Vietnamese in the earbuds, my Vietnamese → subtitles on the board, own-voice gate, turns, conversation on/off, board mic toggle, clear (with confirm), model download, the "Phụ đề" design | A checklist ticked on the iPhone | M | No |
| P3 | B6 | Speech recognition uses the best engine the phone has per language: the OS on-device recognizer (`SpeechTranscriber`, else `DictationTranscriber`) | A unit test of the selection with fake capabilities | M | No online recognizer on the iPhone |
| P4 | B6 | Offline translation with Apple Translation | Airplane mode after the downloads: a conversation works | M | No |
| P5 | B6 | Speech output in Vietnamese (`AVSpeechSynthesizer`); if the Vietnamese voice is missing the app says so and links to the settings | With no Vietnamese voice the app shows the message | M | No |
| P6 | B1 | The app keeps working with the screen off and in the background while a conversation runs (background audio + Bluetooth) | 10 minutes with the screen off: board speech is still spoken, subtitles still reach the board | M | No |
| P7 | B1 | The AirPods mic is used for my voice, with echo cancellation, and other apps' audio is ducked, not stopped, during a conversation | My speech through the AirPods produces subtitles; a YouTube video gets quieter and resumes | M | No |
| P9 | B1 | The app talks to one board only: the first board is pinned once its translator setup finished (trust on first use) and only that identifier is reconnected; "Quên board" clears the pin | Unit tests of `BoardPin`; a second board advertising the service is ignored | M | No proof of identity at the first connection |

### Multi-language (B2)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| R1 | B2 | The user picks the other person's language. My side stays Vietnamese | Pick e.g. Japanese or French: their speech → Vietnamese in the earbuds; my Vietnamese → subtitles in that language on the board. Shown on the iPhone with the log | M | No |
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
| R9 | B3 | Special-word rules are **per-language data files** (JSON assets) run by one rule engine (`RuleEngine`) with today's features (whole word, clause start, context) | Every `VietnameseFixupTests` case passes with the VI rules as data (`rules.json`) | M | No |
| R10 | B3 | **Protected terms**: names, brands, places and glossary entries pass through translation unchanged (or as their fixed translation) | A corpus of ≥ 40 sentences per direction: each term verbatim or as its fixed translation in ≥ 95 % of outputs with Apple Translation | M | No |
| R11 | B3 | **User glossary** in the app: add, edit, delete terms with an optional fixed translation per language. Stored on the phone only | A new term is used from the next phrase; it survives a relaunch | M | No |
| R12 | B3 | Recognition hints from the glossary where the engine accepts them (Apple contextual strings) | A harness run: term recognition with hints ≥ without | S | Synthetic audio only |
| R13 | B3 | Today's VI rewrites (vocatives, service phrases) apply for **every** target language | The ported rewrite tests pass; two non-English targets show no literal vocative in a manual check | M | No |
| R14 | B3 | Starter rule packs for the common travel languages (at least the cross-language brand and loanword rules) | A rule file and tests for every listed language | S | Rules from synthetic measurements |

### Quality and build (B1)

| ID | From | Requirement | Acceptance criterion | Priority | Faked / simplified |
|---|---|---|---|---|---|
| R15 | B1, B3 | Repeatable measurement per language: term accuracy (R10) and recognizer WER. Vietnamese on Apple stays within ±0.6 points of the README table | Harness output in a README table | M | Synthetic TTS voices |
| R16 | B1 | Nothing language-specific hard-coded: languages, rules and fonts come from one language description in `shared/`. The pure logic is driven by the fixtures in `shared/fixtures/` | `grep` finds no locale literals outside `shared/` and the engine's mapping tables. `swift test` passes every fixture case | M | No |
| R17 | B1 | On device: no network in the translator path after downloads. The glossary never leaves the phone | Code review plus an airplane-mode run | M | No |
| R18 | B2 | Auto-detect the other person's language | — | C | Left out this round |
| R20 | B2 | My own language other than Vietnamese | — | W | Left out |
| R21 | B2 | The other person also hears the translation spoken | — | C | Left out this round |

## Faked / simplified / left out

| Item | Kind | Reason |
|---|---|---|
| R7 fallback | Simplified | A font per script is the real fix; transliteration covers most scripts until then |
| R8 CJK subset | Simplified | Full CJK at two sizes is tens of MB |
| R12, R14, R15 synthetic audio | Simplified | Before/after comparisons count |
| P9 first connection | Simplified | Trust on first use; a user-confirmed pairing needs firmware work |
| R18 auto-detect | Left out (Could) | No language ID on the on-device engines |
| R20 any pair | Left out (Won't) | The gate, the vocative rules and the board UI assume my side is Vietnamese |
| R21 speak to them | Left out (Could) | A separate audio design (speaker while the headset holds the mic, echo into the board mic) |
| Cloud/LLM translation | Left out | Offline on device is a core promise |

## Assumptions

1. **Online recognizer**: not used on the iPhone (the catalog supports it, the app never allows it).
2. **Languages**: whatever the iPhone supports offline with Vietnamese; the list may differ per phone (R2).
3. **Release**: none planned; the iOS app runs from Xcode. No TestFlight or App Store work this round.
4. **The board subtitle layout** does not change, apart from the language label and the fonts.
