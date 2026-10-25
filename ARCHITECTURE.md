# Architecture: Flutter app for iOS and Android, multi-language, special-word handling

Date: 2026-10-26. Status: draft for review. Implements `REQUIREMENTS.md` (same date; replaces the iOS-only draft of 2026-10-23).
Assumptions from its open questions hold: Flutter replaces the Swift app after parity, my side is always Vietnamese, the online recognizer is opt-in, Whisper models are downloaded on first use, Android 10 is the minimum, and there is no store release.

## 1. Overview

```
app/ (Flutter)
├── lib/                Dart: UI ("Phụ đề" design), state, and ALL pure logic (ported from TranslatorCore + new)
│   ├── core/           LanguageCatalog, RuleEngine, TermProtector, TextPipeline, BoardText, Glossary,
│   │                   TurnAssembler, ConversationActivity, SubtitleTranslator, board protocol (framing, ADPCM)
│   ├── engine/         ConversationController: the state machine, wires core ↔ platform
│   └── ui/             screens
├── ios/Runner/Native/  Swift: VoiceEngine (audio session, mic, VoiceGate, SpeechAnalyzer, Translation, TTS)
└── android/…/native/   Kotlin: VoiceEngine (foreground service, SCO mic, VoiceGate, recognizer chain, ML Kit, TTS)
                        + whisper.cpp (C++, built with the NDK)
firmware/               board: Latin Extended-A, language label, board info, font partition (CJK/Thai)
ios/                    the Swift app: frozen until parity (P8), then removed
```

The phone-specific work (audio, speech, translation, speech output) stays native, because it is real-time audio and is
exactly what differs between platforms. Everything that decides *what* happens (turns, rules, terms, glossary,
languages, board text, conversation on/off) is Dart and tested once with `flutter test`. Bluetooth to the board is
Dart (`flutter_blue_plus`), because the protocol is the same on both and the audio rate is small (ADPCM).

```
Them → You  Board mic ─BLE(Dart)─► ADPCM decode ─► native: Recognizer(X) ─final─► Dart: TextPipeline(X→vi) ─► native: Translate(X→vi)
                                                                                   ─► Dart: restore terms ─► native: TTS vi ─► earbuds

You → Them  earbuds mic ─► native: VoiceGate ─► Recognizer(vi) ─events─► Dart: TurnAssembler ─► TextPipeline(vi→X)
                                                                        ─► native: Translate(vi→X) ─► Dart: restore ─► BoardText ─BLE─► AMOLED
```

## 2. Main flow, end to end

1. **Launch.** Dart asks the native side for capabilities (`VoiceEngine.capabilities()`): per language, which recognizers exist (on-device OS, Whisper model present or downloadable, online OS), translation support both ways with Vietnamese, and TTS voices. `LanguageCatalog` combines them with the bundled language packs and lists the languages that work fully (R2). The last pick comes from `shared_preferences`; with none, English.
2. **Readiness.** For the pick, Dart asks what is missing (speech model, translation models X→vi and vi→X, the Vietnamese voice) and shows it with a Download button (R3). Downloads run natively: Apple `AssetInventory` and `TranslationSession.prepareTranslation`; ML Kit `RemoteModelManager`; the Whisper model over HTTPS with a checksum. A failed or cancelled download returns to "missing" with the error (the bug fixed in `3f23288` stays fixed).
3. **Board.** Dart scans for the service, connects, reads board info (`…0005`, section 5), subscribes to audio and control, sends the clock and the language label.
4. **Start.** The native `VoiceEngine.start(pair)` prepares the recognizers, the translators and TTS. On Android it starts the foreground service (P6). The conversation on/off rules (`ConversationActivity`, ported) decide when the earbuds mic is held, as today.
5. **Them → You.** Each board audio packet is decoded in Dart (ADPCM, gap filling) and sent as PCM to the native recognizer for X. A final phrase comes back with its confidence; Dart applies the per-language confidence gate and `TextPipeline(X→vi).prepare`, asks the native translator, applies `restore`, and asks native TTS to speak (one queue; strict order, as today).
6. **You → Them.** The native side runs the mic, the `VoiceGate` (ported to Swift/Kotlin from the same tests) and the Vietnamese recognizer, and streams partial/final events. Dart runs `TurnAssembler`, `TextPipeline(vi→X)`, `SubtitleTranslator` (through the native translator), `restore`, `BoardText`, and writes the subtitle.
7. **Switch language** (R4). Dart increments the *their* generation, tells native to swap the X recognizer and translators, and sends the new label. Late results with the old generation are dropped.
8. **Glossary edit** (R11). Saved by Dart; pipelines rebuild; hints go to the native recognizer (R12).

## 3. State machines

**Session** (Dart `ConversationController`; replaces the Swift `Phase`):

| State | Meaning | Event → next state |
|---|---|---|
| `loading` | Capabilities and packs being read | saved pick offered → `checking(X)` · not offered → `choosing` |
| `choosing` | Language list shown | pick X → `checking(X)` |
| `checking(X)` | What is missing for X↔vi | all present → `preparing(X)` · missing → `needsDownload(X, missing)` |
| `needsDownload(X, missing)` | Lists the missing parts | Download → `downloading(X)` · pick Y → `checking(Y)` |
| `downloading(X)` | Progress shown | done → `preparing(X)` · error/cancel → `needsDownload` with the error |
| `preparing(X)` | Native engine starting | ok → `running(X)` · error → `failed(X, reason)` |
| `running(X)` | Translating | pick Y → `switching(X→Y)` · their recognizer dies → `preparing(X)` once, then `failed` |
| `switching(X→Y)` | Old *their* side torn down | Y ready → `preparing(Y)` · Y missing → `needsDownload(Y)` |
| `failed(X, reason)` | Retry shown | Retry → `checking(X)` · pick Y → `checking(Y)` |

**Conversation on/off** (`ConversationActivity`): unchanged rules, ported to Dart with its tests, including the stop tap added in `3f23288`.

**Board link** (Dart): `off → scanning → connecting → ready`, reconnect on drop, as the Swift `ESPLink`.

## 4. Data model (Dart)

```dart
class LanguagePack {            // assets/languages/<code>.json
  final String code;            // BCP-47: "ja", "fr", "zh-Hans"
  final String appleLocale;     // "ja-JP" (SpeechAnalyzer)
  final String androidLocale;   // "ja-JP" (SpeechRecognizer / ML Kit "ja")
  final String whisperCode;     // "ja"
  final String label, labelLatin;  // "日本語", "JA"
  final Script script;          // latin, cjk, hangul, thai, cyrillic…
  final double? minConfidence;  // their-side gate; null = engine gives none (Whisper: uses avg log-prob mapped)
  final List<Rule> recognition, beforeTranslation;
  final List<Term> terms;
  final List<String> hints;
}

class Rule { String id, pattern, template; bool atClauseStart; String? context; }
class Term { String id, text; List<String> variants; Map<String, String> fixed; Origin origin; }

enum RecognizerKind { osOnDevice, whisper, osOnline }

class Capabilities {            // from native, per language code
  final Map<String, List<RecognizerKind>> recognizers;   // available or downloadable, best first
  final Set<String> translatable;                       // both ways with "vi"
  final bool vietnameseVoice;
}

class BoardInfo { final int protocolVersion; final FontSets fontSets; }   // latinVI, latinExtA, cjk, hangul, thai
```

- Glossary: JSON in the app's support directory (excluded from iCloud backup on iOS; app-private storage on Android). Limits: 500 terms, 64 characters each, 8 variants.
- Pick and settings (online fallback consent per language, Whisper model size): `shared_preferences`.

## 5. Interfaces and contracts

**Dart ↔ native** (one `MethodChannel` `translator/engine` for calls, one `EventChannel` `translator/events` for streams; generated with `pigeon` so both sides are typed):

| Call | Contract |
|---|---|
| `capabilities() → Capabilities` | Fast (no downloads). Called at launch and after any download |
| `missing(pair) → List<Missing>` / `download(item)` | Download progress and result arrive as events |
| `start(pair, recognizerX, hints)` / `stop()` | Idempotent. `start` holds the mic only when `ConversationActivity` says so (`micOn(bool)`) |
| `feedTheirAudio(Int16List pcm, int sampleRate)` | PCM from the board, 16 kHz mono |
| `translate(text, from, to) → String` | Throws a typed error; Dart decides the fallback |
| `speak(text, id)` / `stopSpeaking()` | Events `ttsStart(id)`, `ttsEnd(id)` |
| `setHints(List<String>)` | No-op where unsupported |

| Event | Payload |
|---|---|
| `mine` | partial / final text, timestamps (`TurnAssembler` input) |
| `theirs` | final text, confidence, generation |
| `gate` | open / closed (for `ConversationActivity`) |
| `audioSession` | interrupted / resumed / route changed |
| `download` | item, progress, done / error |

**Recognizer chain** (P3; native, per language, chosen by Dart from `capabilities`):

| Platform | 1st | 2nd | 3rd (opt-in, marked online) |
|---|---|---|---|
| iOS 26 | `SpeechTranscriber`, else `DictationTranscriber` (on device) | Whisper (same C++ core, built for iOS) | — (Apple's are already on device) |
| Android 13+ | `SpeechRecognizer.createOnDeviceSpeechRecognizer` if the language is supported | Whisper | `SpeechRecognizer` (Google, online) |
| Android 10–12 (Note 9) | — | Whisper | `SpeechRecognizer` (online) |

Whisper runs on utterances cut by the existing gate / board silence detection, with a sliding 30 s window; no live partials (the UI shows "…").

**BLE** (Dart; backward compatible with the current board):

| Item | Change |
|---|---|
| `…0002` audio, `…0004` control, `…0003` kinds 0–2 | Unchanged |
| `…0003` **kind 3 = language label** | New. UTF-8, ≤ 32 bytes. Sent only if `…0005` exists (old firmware shows unknown kinds as subtitles) |
| `…0005` **board info**, read | New. `[version u8][fontSets u32 LE]`. Missing → `latinVI` |
| Claude service `A7C00010-…` | Unchanged; the Flutter app does not use it (P9) |

**Firmware:** Latin Extended-A in the compiled fonts; the status line appends the label; `glyphs.c` shared with ANCS; non-Latin fonts from a `fonts` partition (D3).

## 6. Errors and failure states

| Failure | Behavior |
|---|---|
| No recognizer for X on this phone, and online not allowed | X is not offered; the list footer says why and offers the online opt-in |
| Whisper too slow on this phone (measured real-time factor > 1) | The app falls back to the next recognizer in the chain and logs it; the user sees "online" if that is the next one |
| Download fails / cancelled / no network | `needsDownload` with the error and Retry |
| Vietnamese TTS voice missing (Android) | Banner with a button to the system TTS settings; translations shown as text until fixed |
| Their recognizer dies | One restart, then `failed(X)`; the *you* side keeps running |
| Translator throws | Their side: phrase skipped and logged. Subtitles: the source text kept |
| Term placeholder lost | Translate the unmasked text and replace fixed terms where found; counted in the metric |
| Board character missing | `BoardText` fallback; never empty |
| Old board firmware | `latinVI`; non-Latin targets transliterated, with a "update the board" hint |
| Android kills the service / iOS suspends | Android: foreground service + battery-optimization exemption prompt; iOS: the same silent keep-alive as the Swift app. The board link reconnects on return |
| Bluetooth SCO unavailable (Android) | Phone mic used, with a warning chip "mic điện thoại" |
| Glossary file corrupt | Renamed aside, empty glossary, user told |

## 7. Security and untrusted input

No LLM is used, so prompt injection does not apply.

| Input | Handling |
|---|---|
| Recognized speech and translator output | Untrusted text: never a regex or format string; length bounded |
| Glossary terms (typed) | Literal: escaped (`RegExp.escape`) before matching; length/count limits; control and bidi-override characters rejected |
| Bundled packs | Validated at load; every regex tested against a 2 KB adversarial string with a time bound |
| Whisper model download | HTTPS from a fixed URL, SHA-256 checked against a value in the app before use |
| BLE | Label ≤ 32 bytes, subtitles chunked as today; the board validates UTF-8 |
| Android permissions | `RECORD_AUDIO`, `BLUETOOTH_SCAN/CONNECT` (or location on Android 10–11 for scanning), `FOREGROUND_SERVICE` (microphone type), `POST_NOTIFICATIONS` where needed. Asked when first used, with a reason |
| Privacy | Offline except the opt-in online recognizer, which is marked in the UI while used. Glossary on the phone only, no telemetry |

## 8. How quality is measured (R15)

1. **`flutter test`**: every ported Swift test (turns, activity, subtitle translator, VI fix-ups, ADPCM) plus the new core (catalog, rules, terms, board text, glossary, controller state machine with fake native).
2. **Native unit tests**: `VoiceGate` in Swift (`XCTest`) and Kotlin (JUnit) against the same fixture WAVs as today, so both ports match the original.
3. **Term accuracy** (`tool/harness terms <lang>`): the corpus through each platform's translator (Apple on the Mac, ML Kit on the Note 9 via an instrumented test). Target ≥ 95 % per platform.
4. **Recognition WER** per engine: Apple (Mac, as today), Whisper (Mac and Note 9), Android on-device (if a test phone has it). Vietnamese on Apple within ±0.6 points of the README table.
5. **On device**: the parity checklist (P2), airplane mode, switch time from the logs, 10 minutes screen-off (P6), board photos per script.

Results go in README tables.

## 9. Big choices

### D1. Where the audio and speech work lives

| | A. Native engine per platform, logic in Dart | B. Everything in Dart with community plugins |
|---|---|---|
| How | A Swift and a Kotlin `VoiceEngine` (mic, gate, recognizers, translator, TTS, audio session) behind one typed channel | `speech_to_text`, `flutter_tts`, `google_mlkit_translation`, `record`, `audio_session` plugins; gate in Dart |
| Strength | Keeps the measured iOS audio behaviour (voice chat, ducking, keep-alive, SpeechAnalyzer with confidence); real-time audio off the Dart isolate; Whisper fits naturally | Less native code |
| Weakness | Two native engines to write and test | Plugins don't expose SpeechAnalyzer, Apple Translation, confidence, SCO routing or the keep-alive; real-time PCM through Dart costs latency and battery; the iOS behaviour tuned over weeks would regress |

**Recommendation: A.** The Swift engine pieces move almost as-is into `app/ios/Runner/Native/`; the Kotlin side is new.

### D2. Protecting names and terms (R10)

Placeholder masking (translate with a token, swap back), with the token shape chosen per pair and per platform translator by a spike on the term corpus; "translate, then repair" only as the fallback when a placeholder is lost. Recommended over repair-only because it is exact and target-independent. (Unchanged from the iOS draft, now run against both Apple Translation and ML Kit.)

### D3. Non-Latin fonts on the board (R8)

Fonts in their own flash partition loaded at runtime (`lv_binfont_create_from_buffer`), versus compiled into the 6 MB app. **Recommendation: partition.** Latin Extended-A stays compiled in so the Must (R6) does not depend on it. (Unchanged from the iOS draft.)

## 10. Other trade-offs taken

- **The Swift app is frozen, not deleted**, until parity (P8), so the user always has a working iPhone app.
- **The Claude relay ends with the Swift app** (B8). The board's Claude service stays in the firmware, unused by the Flutter app.
- **Whisper is downloaded on first use**, not bundled: a small APK, one more download step.
- **Board Bluetooth in Dart** (`flutter_blue_plus`): one implementation; iOS background Bluetooth needs the `bluetooth-central` mode, as the Swift app has.
- **Home language fixed to Vietnamese** (R20 Won't).
- **Synthetic audio for measurement**, as today.

## 11. Build order

1. **Toolchain**: install Flutter, the Android SDK/NDK and Java; `flutter doctor` clean; adb on the Note 9 (done).
2. **Board** (B7, first): Latin Extended-A fonts, language label (kind 3), board info (`…0005`), shared `glyphs.c`, host tests, flash. Then the font partition and CJK/Thai (Should).
3. **Dart core**: port the Swift `TranslatorCore` logic and tests; add catalog, rules as data, terms, board text, glossary, controller (all against a fake native).
4. **iOS native engine**: move the Swift audio/speech/translation/TTS into the plugin; run the Flutter app on the iPhone; parity checklist on iOS.
5. **Android native engine**: foreground service, SCO, ML Kit, TTS, recognizer chain, whisper.cpp; parity checklist on the Note 9.
6. **Multi-language end to end**, D2 spike, R10/R15 measurement, README tables.
7. Retire the Swift app (P8).

## 12. Must coverage

| Must | Covered by |
|---|---|
| P1 one Flutter app | §1, §11 |
| P2 parity | §2, ported tests §8.1, checklist §8.5 |
| P3 recognizer chain | §5 table, §6, `Capabilities` |
| P4 offline translation | §5 native `translate`, §2.2 downloads |
| P5 Vietnamese TTS | §5 `speak`, §6 missing voice |
| P6 background | §6, D1 (native engines, foreground service) |
| P7 headset mic | D1, §6 SCO fallback (Android quality is a **risk**) |
| P8 Swift app kept until parity | §10, §11.7 |
| P9 no Claude relay | §5 BLE table |
| R1–R7 | §2, §3, §4, §5 (as in the iOS draft) |
| R9–R11, R13 | `RuleEngine`, `TermProtector`, glossary, `vi.json` `beforeTranslation` |
| R15 measurement | §8 |
| R16 nothing hard-coded | `LanguagePack`, catalog |
| R17 on device | §7 |

**Risks the design cannot prove before measuring:** R4's 3 s switch (Whisper model load on the Note 9), R10's 95 % (per platform translator), P7 audio quality over SCO, and Whisper's speed on the Note 9. Each is measured early in its build step, with the fallback named in §6.

## 13. Left to the builder

- The exact `pigeon` schema, the package layout inside `lib/`, and the state management library (Riverpod or plain `ChangeNotifier`, matching the small scope).
- Whisper model size per device (from measured real-time factor), the token shape per pair, the CJK character lists.
- Screen layouts for the language list and glossary, inside the existing "Phụ đề" design.
