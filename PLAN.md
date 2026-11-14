# Live translator (ESP32 board + Swift iPhone app), multi-language: plan

> Every task is TDD: write the failing test, see it fail, implement, see it pass, commit.

**Goal:** the iPhone app does a two-way conversation with a choice of the other person's language, data-driven
special-word rules, protected terms and a user glossary; the board shows the subtitles in that language.

**Architecture:** `ARCHITECTURE.md`. Pure logic in `ios/Sources/Core` (and a few files in `App`, `Audio`,
`Translate`) is driven by the fixtures in `shared/fixtures/`; the platform work sits behind `VoiceEngine` and
`BoardLink`, each with a fake. Language packs and board glyph lists live in `shared/` and are loaded at run time.

**Tech stack:** iOS 26, Swift 6 (language mode 5), SwiftUI, `swift test` on the Mac (no simulator), XcodeGen
`ios/project.yml`. ESP-IDF 5.5 + LVGL 9.6 on the board.

**Spec:** `REQUIREMENTS.md`, `ARCHITECTURE.md`.

## Global constraints

- Test devices: the board and the user's iPhone (iOS 26). **Never** start an iOS simulator.
- Home language is always Vietnamese (`vi`); the other language is picked (R20 Won't).
- No network in the translator path except model downloads (R17).
- No locale literal (`"en-US"`, `"vi-VN"`, `"ja"`…) outside `shared/languages/*.json`, the catalog and the engine's
  mapping tables (R16).
- BLE service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`, characteristics `…0002`–`…0005`, text kind 3 (label ≤ 32 bytes
  UTF-8), `…0005` `[version u8][fontSets u32 LE]` (latinVI 1, latinExtA 2, cjk 4, hangul 8, thai 16), as implemented
  by `firmware/main/ble_link.c` and `ios/Sources/Core/BoardProtocol.swift`.
- UI copy is Vietnamese (`shared/copy/vi.json`), in the "Phụ đề" design: black ground, accent `#1E6FD9`, light accent
  `#4C8FE8`, text `#E3EAF0`, muted `#8A919C`, faint `#5E646D`, surface `#16171A`.
- Glossary limits: 500 terms, 64 characters per term, 8 variants; control and bidi-override characters
  (U+202A–U+202E, U+2066–U+2069) rejected. Stored on the phone only.
- **Fixtures are the contract.** A change that cannot pass a fixture case stops and reports; it never edits the
  fixture silently.

## Review focus

1. **Board drops and reconnects mid-conversation** → on `ready` the app resends the clock (kind 2) and the label
   (kind 3); a stale write failing after a services reset must not wipe the new queue (`BoardLinkLogicTests`).
2. **Language switch while translations are queued for speech** → nothing from the old pair is spoken after the
   switch (generations; `ConversationControllerTests`).
3. **Glossary terms with regex characters or overlapping each other** (`C++`, `Q.1`, `Bến Thành` / `Chợ Bến Thành`)
   → matched literally, longest first, never double-masked; a lost or invented placeholder → `restore` fails and the
   fallback path runs (`terms.json`).

## Done

| Step | What | Proof |
|---|---|---|
| Board | Latin Extended-A fonts, language label (kind 3), board info (`…0005`), CJK / Hangul / Thai fonts from a partition, lock screen | firmware host tests, simulator, photos |
| Shared data | `shared/languages`, `shared/board_glyphs`, `shared/copy`, `shared/fixtures` | `swift test` reads them in place |
| S1 Swift core | RuleEngine, TermProtector, TextPipeline, BoardText + Translit + BoardGlyphSets, Glossary, LanguageCatalog, SessionMachine | every fixture case green |
| S2 Engine + BLE | `AppleVoiceEngine` behind `VoiceEngine`; `ESPLink` with label, board info, services reset, keepalive, board pinning | `swift test`; device build |
| S3 UI | Language sheet, readiness/download view, glossary screen, chips | device build, `ios/Preview/run.sh` |
| P2.2 Controller | `ConversationController` + wiring in `ESPTranslatorApp` | `ConversationControllerTests` |
| P2.5 Term harness | `ios/Tools/term-harness`, corpus `shared/fixtures/terms/<lang>.tsv` | `swift test` in the harness |
| P2.7 Starter packs | ja, ko, zh-Hans, th, fr, de, es | fixture cases |

## Next

| Task | Req. | Proof |
|---|---|---|
| iPhone parity run | P2, P6, P7 | checklist ticked on the iPhone, 10 min screen-off, airplane mode |
| Term accuracy per language | R10 | README table filled from `swift run term-harness`; best shape written into each pack |
| Recognizer WER per language | R12, R15 | README table filled; Vietnamese within ±0.6 of the first table |
| Open items | — | the "Not done / next" list in the README |

## Cut order if late

1. Starter packs beyond `en` (R14, S)
2. R12 recognition hints (S)
3. Per-language WER tables (keep the Vietnamese regression check)
