# Architecture: ESP32 board + iPhone live translator, multi-language, special-word handling

Implements `REQUIREMENTS.md`. Two parts only: the ESP32 board (microphones, BLE, round AMOLED) and the Swift
iPhone app. Home language is always Vietnamese; the other language is picked from the packs in `shared/languages/`.

## 1. Overview

```
firmware/               ESP32-S3 board: 2 mics → VAD → IMA ADPCM over BLE; subtitles, language label, lock face;
                        Latin + Vietnamese compiled fonts, CJK / Hangul / Thai fonts from a flash partition (D3)
ios/                    the iPhone app (SwiftUI)
├── Sources/Core        pure logic: Model, SessionMachine, RuleEngine, TermProtector, TextPipeline, BoardText,
│                       Translit, BoardGlyphSets, Glossary, LanguageCatalog, BoardProtocol, BoardLink, VoiceEngine
│                       (contract) + fakes
├── Sources/App         ConversationController (wires core ↔ engine ↔ board), ConversationActivity, TurnAssembler
├── Sources/Audio       VoiceGate (own-voice gate), ADPCMDecoder
├── Sources/Engine      AppleVoiceEngine: audio session, mic, SpeechAnalyzer per language, Translation, AVSpeech, downloads
├── Sources/Translate   SubtitleTranslator, VietnameseFixup
├── Sources/BLE         ESPLink (CoreBluetooth) + its pure bookkeeping (BoardLinkLogic: write queue, label, backoff, pin)
└── Sources/UI          ContentView ("Phụ đề" design), LanguageSheet, ReadinessView, GlossaryView, UIState
shared/                 languages/*.json (packs), board_glyphs/*.txt (board font code points), copy/vi.json (UI copy),
                        fixtures/ (the behaviour contract the Swift suite runs)
sim/                    the board's screens on the Mac (LVGL + SDL2)
```

Everything that decides *what* happens (turns, rules, terms, glossary, languages, board text, conversation on/off,
the session state machine) is pure Swift in `Sources/Core` (and a few files in `App`, `Audio`, `Translate`) and runs
under `swift test` on the Mac, driven by `shared/fixtures/`. The platform work (audio, speech, translation, speech
output, Bluetooth) sits behind two protocols with fakes: `VoiceEngine` and `BoardLink`.

```
Them → You  Board mic ─BLE─► ADPCM decode ─► Recognizer(X) ─final─► TextPipeline(X→vi) ─► Translate(X→vi)
                                                                     ─► restore terms ─► TTS vi ─► AirPods

You → Them  AirPods mic ─► VoiceGate ─► Recognizer(vi) ─events─► TurnAssembler ─► TextPipeline(vi→X)
                                                                  ─► SubtitleTranslator ─► restore ─► BoardText ─BLE─► AMOLED
```

## 2. Main flow, end to end

1. **Launch.** The controller asks the engine for capabilities (`capabilities(home: "vi")`): per language, which
   recognizers exist, translation support both ways with Vietnamese, and the Vietnamese voice. `LanguageCatalog`
   combines them with the bundled packs and lists the languages that work fully (R2). The last pick comes from
   `UserDefaults`.
2. **Readiness.** For the pick, the engine reports what is missing (speech model, translation models X→vi and vi→X,
   the Vietnamese voice); the readiness view lists it with a Download button (R3). Downloads use `AssetInventory`
   and `TranslationSession.prepareTranslation`. A failed download returns to "missing" with the error.
3. **Board.** `ESPLink` scans for the service (or reconnects the pinned board by identifier), reads board info
   (`…0005`), subscribes to audio and control, sends the clock (kind 2) and the language label (kind 3), turns the
   board mic on and starts the 20 s keepalive. The first board whose setup finishes is pinned (§7).
4. **Start.** `start(pair, recognizerX, hints)` prepares the recognizers, the translators and TTS. `ConversationActivity`
   decides when the AirPods mic is held (see the README, "Conversation on / off").
5. **Them → You.** Each board audio packet is decoded (ADPCM, gap filling) and fed as PCM to the recognizer for X. A
   final phrase comes back with its confidence; the per-language confidence gate and `TextPipeline(X→vi).prepare`
   run, the engine translates, `restore` runs, and the phrase is spoken (one queue, strict order).
6. **You → Them.** The engine runs the mic, the `VoiceGate` and the Vietnamese recognizer and streams partial/final
   events. The controller runs `TurnAssembler`, `TextPipeline(vi→X)`, `SubtitleTranslator`, `restore`, `BoardText`,
   and writes the subtitle.
7. **Switch language** (R4). The controller bumps the *their* generation, the engine swaps the X recognizer and
   translators, the new label goes to the board. Late results with the old generation are dropped.
8. **Glossary edit** (R11). Saved to a JSON file; pipelines rebuild; hints go to the recognizer (R12).

## 3. State machines

**Session** (`SessionMachine`, driven by `ConversationController`; fixture `session_machine.json`):

| State | Meaning | Event → next state |
|---|---|---|
| `loading` | Capabilities and packs being read | saved pick offered → `checking(X)` · not offered → `choosing` |
| `choosing` | Language list shown | pick X → `checking(X)` |
| `checking(X)` | What is missing for X↔vi | all present → `preparing(X)` · missing → `needsDownload(X, missing)` |
| `needsDownload(X, missing)` | Lists the missing parts | Download → `downloading(X)` · pick Y → `checking(Y)` |
| `downloading(X)` | Progress shown | done → `checking(X)` · error → `needsDownload` with the error |
| `preparing(X)` | Engine starting | ok → `running(X)` · error → `failed(X, reason)` |
| `running(X)` | Translating | pick Y → `switching(X→Y)` · their recognizer dies → `preparing(X)` once, then `failed` |
| `switching(X→Y)` | Old *their* side torn down | Y ready → `preparing(Y)` · Y missing → `needsDownload(Y)` |
| `failed(X, reason)` | Retry shown | Retry → `checking(X)` · pick Y → `checking(Y)` |

**Conversation on/off** (`ConversationActivity`, fixture `conversation_activity.json`): when the AirPods mic is held.

**Board link** (`ESPLink`): `off → scanning → connecting → ready`; reconnect on drop with backoff (first rescan at
once, then 0.5 s doubling to 10 s); a services reset is set up again on the same connection.

## 4. Data model (`Sources/Core/Model.swift`)

- `LanguagePack` (`shared/languages/<code>.json`): `code` (catalog code: `ja`, `zh-Hans`), `appleLocale`, `label`,
  `labelLatin`, `script` (latin, cjk, hangul, thai, …), `minConfidence` (their-side gate), `recognition` and
  `beforeTranslation` rules, `terms`, `hints`. Schema: `shared/fixtures/README.md` (model.json, rules.json).
- `Rule { id, pattern, template, atClauseStart, context? }`, `Term { id, text, variants, fixed[lang], origin }`.
- `Capabilities { recognizers[code]: [RecognizerKind], translatable, vietnameseVoice }`.
- `BoardInfo { protocolVersion, fontSets }` with `FontSets` latinVI 1, latinExtA 2, cjk 4, hangul 8, thai 16.
- Glossary: JSON in Application Support, excluded from iCloud backup. Limits: 500 terms, 64 characters each,
  8 variants. Pick and settings: `UserDefaults`.

## 5. Interfaces and contracts

### R3. Voice engine (`protocol VoiceEngine`, in-process)

Implemented by `AppleVoiceEngine`; `FakeVoiceEngine` for tests. Async calls, events as broadcast `AsyncStream`s.

| Call | Contract |
|---|---|
| `capabilities(home:)` | Fast (no downloads). Called at launch and after any download |
| `missing(pair:)` / `downloadItem(_:)` | Progress and result arrive on the `download` stream |
| `start(pair:recognizerX:hints:)` / `stop()` / `micOn(_:)` | Idempotent. The mic is held only when `ConversationActivity` says so |
| `feedTheirAudio(_:sampleRate:)` | PCM from the board, 16 kHz mono |
| `translate(_:from:to:)` | Throws `EngineError.translateFailed`; the caller decides the fallback |
| `speak(_:id:)` / `stopSpeaking()` | Events `ttsStart(id)`, `ttsEnd(id)` |
| `setHints(_:)` | Contextual strings where supported |

Events: `mine` (partial / final, timestamps), `theirs` (final text, confidence, generation), `gate`,
`audioSession` (interrupted / resumed / route changed), `download`.

Recognizer per language: Apple `SpeechTranscriber`, else `DictationTranscriber`, on device. `LanguageCatalog` can
also chain an online recognizer when allowed and consented; the app does not allow it.

### R4. Bluetooth (`protocol BoardLink`, implemented by `ESPLink`)

Service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`, the board's only one (full table in the README):

| Item | Contract |
|---|---|
| `…0002` audio, notify | `[seq u16][predictor i16][index u8][IMA ADPCM]`, 16 kHz mono, 20 ms per packet |
| `…0003` text, write | `[flags][kind][UTF-8]` chunks; kinds 0 subtitle, 1 status, 2 time, 3 language label (≤ 32 bytes, sent only when `…0005` exists) |
| `…0004` control | mic 0 / 1; `0xFF` keepalive every 20 s; the board stops streaming after 60 s without an app write |
| `…0005` board info, read | `[version u8][fontSets u32 LE]`; missing → `latinVI` |

On every `ready` the clock and the label are resent (the board forgets them). Subtitles go through a
generation-guarded write queue, so a stale write failing after a services reset never clears the new link's queue.

## 6. Errors and failure states

| Failure | Behaviour |
|---|---|
| No recognizer or no offline translation for X | X is not offered; the list footer says why |
| Download fails / no network | `needsDownload` with the error and Retry |
| Vietnamese TTS voice missing | Banner with a button to the system settings; translations shown as text |
| Their recognizer dies | One restart, then `failed(X)`; the *you* side keeps running |
| Translator throws | Their side: phrase skipped and logged. Subtitles: the source text kept |
| Term placeholder lost | Translate the unmasked text and replace fixed terms where found; counted in the metric |
| Board character missing | `BoardText` transliterates or falls back; never an empty subtitle |
| Old board firmware (no `…0005`) | `latinVI`, no label |
| iOS suspends the app | Background audio (mixable silence while idle) + `bluetooth-central`; the board link reconnects on return |
| AirPods lost mid-conversation | Phone mic with the "mic điện thoại" chip |
| Glossary file corrupt | Renamed aside, empty glossary |

## 7. Security and untrusted input

No LLM is used, so prompt injection does not apply.

| Input | Handling |
|---|---|
| Recognized speech and translator output | Untrusted text: never a regex or format string; length bounded |
| Glossary terms (typed) | Matched literally (escaped); length/count limits; control and bidi-override characters rejected |
| Bundled packs | Validated at load; patterns restricted to a portable regex subset (`rules.json` `portableSyntax`) |
| BLE from the board | ADPCM header index clamped; board info parsed defensively; label ≤ 32 bytes, subtitles chunked |
| Which board (P9) | Trust on first use: the first board whose translator setup finishes is pinned (`BoardPin`, identifier in `UserDefaults`); afterwards only that identifier is reconnected and no other device advertising the service is connected. "Quên board" clears the pin. No proof of identity at the first connection (see README, "Not done") |
| Privacy | Offline after downloads. Glossary on the phone only, no telemetry |

## 8. How quality is measured (R15)

1. **`cd ios && swift test`**: the core, controller, engine (on fakes) and BLE bookkeeping, every case of
   `shared/fixtures/`.
2. **Term accuracy** (`ios/Tools/term-harness`): the corpus `shared/fixtures/terms/<lang>.tsv` through Apple
   Translation on the Mac, per placeholder shape. Target ≥ 95 %.
3. **Vietnamese WER** (`ios/Tools/vi-harness`): within ±0.6 points of the README table.
4. **Board**: host tests in `firmware/test/`, the simulator, photos per script.
5. **On device**: the iPhone parity run, airplane mode, switch time from the logs, 10 minutes screen-off.

Results go in README tables.

## 9. Big choices

### D2. Protecting names and terms (R10)

Placeholder masking (translate with a token, swap back), with the token shape chosen per pair by the term harness;
"translate, then repair" only as the fallback when a placeholder is lost. Exact and target-independent.

### D3. Non-Latin fonts on the board (R8)

Fonts in their own flash partition loaded at runtime (`lv_binfont_create_from_buffer`) instead of compiled into the
6 MB app. Latin Extended-A stays compiled in, so Latin languages (R6) do not depend on the partition.

## 10. Other trade-offs taken

- **Home language fixed to Vietnamese** (R20 Won't).
- **Synthetic audio for measurement**: before/after differences count.
- **The board never asks for encryption**: pinning by identifier is the access control (§7).
