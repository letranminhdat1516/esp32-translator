# Term corpus and harness cases (P2.5, R10)

R10: names, brands, places and glossary entries come through translation unchanged, or as their fixed
translation, in at least 95 % of outputs, for each platform's translator. This folder holds the corpus
that measures it and the cases that pin the harness logic on both platforms.

| File | What |
|---|---|
| `<lang>.tsv` | The corpus for one language paired with Vietnamese: `en`, `fr`, `de`, `es`, `ja`, `ko`, `zh-Hans`, `th`. Each has 42 sentences per direction (`<lang>>vi` and `vi><lang>`). |
| `harness.json` | Cases for parsing, scoring, the scripted fake, the report and the pack update. `ios/Tools/term-harness` (`swift test`) and `android/__tests__/termHarness.test.ts` (`npm test`) must both pass them. |

## Corpus format

UTF-8 text with one sentence per line and four tab-separated columns:

```
direction<TAB>source sentence<TAB>term<TAB>expected
en>vi	We are flying to Phu Quoc next weekend.	Phu Quoc	Phú Quốc
vi>ja	Khách sạn ở gần hồ Hoàn Kiếm.	Hoàn Kiếm	ホアンキエム
vi>en	Tôi đã đặt Grab ra sân bay rồi.	Grab	Grab
```

- `direction` is `<lang>>vi` or `vi><lang>`, where `<lang>` is the file name without `.tsv`
  (a catalog code: `zh-Hans`, not `zh`). Any other pair is an error.
- `source sentence` is the text to translate. It must contain `term`.
- `term` is the protected name, brand, place or glossary entry, exactly as written in the source.
- `expected` is what the translation must contain. If it equals `term`, the term must come through
  verbatim. If it differs, it is the term's fixed translation for the target language. For example,
  `Hà Nội` becomes `Hanoi` in English and `ハノイ` in Japanese, and `ベンタイン` becomes `Bến Thành`.
- Blank lines and lines starting with `#` are ignored, and a trailing CR is dropped. Fields cannot hold
  tabs or newlines.
- A line with a column count other than 4, a bad direction or an empty field is an error that names
  the line number (`columns`, `direction` or `empty`).

The Vietnamese sentences (`vi>X`) are the same 42 in every file, so languages can be compared. The
brands, personal names and products with digits (`iPhone 15`, `VN 301`, `Landmark 81`) stay verbatim.
Vietnamese places have fixed translations into CJK and Thai (and `Hà Nội`, `Thành phố Hồ Chí Minh` and
`Đà Nẵng` into the Latin-script languages too).

**Latin terms in CJK, Korean and Thai sentences are set off by spaces or punctuation**, for example
`空港まで Grab を予約しました。` or `Grab 택시를`. TermProtector only masks a term whose edge is a letter
or digit at a word boundary, and in its regex a kana, Hangul or Thai letter is a letter. So `Grabを`
and `Grab을` are not masked (fixture case "Latin term glued to kana is not masked"). In real speech
this is the usual way to write these, so the result on such text will be worse than the corpus shows.
The corpus tests in both suites check that every term is masked with every shape.

## Scoring rule (identical in Swift and TypeScript)

For each line and each placeholder shape in `Zorvik{n}`, `[[{n}]]`, `TERM{n}`, `⟦{n}⟧` and `__{n}__`:

1. The line becomes one term: `{id: term, text: term, fixed: expected ≠ term ? {to: expected} : {}}`.
2. `mask(source, [term], to, shape)` with the app's TermProtector. If nothing is masked, the line is an
   error (`termNotFound`).
3. Translate the masked text, then call `restore`. If it succeeds, the line is **kept**.
4. If restore fails (a placeholder was lost, duplicated or invented), the line is **lost**. As the app's
   TextPipeline does, the plain source is translated and each fixed term found as written in the source
   (whole word, same case) is replaced by its fixed translation.
5. The line **passes** if the output contains `expected`. Both strings are compared in NFC, with exact
   case, anywhere in the text. Restoring always inserts `expected`, so a kept line always passes.
6. A translator error counts as lost and failed, and is listed.

Accuracy = passes / lines. `lost` = lines whose placeholders did not survive. The **best shape** of a
language is the one with the most passes over both directions, then the fewest lost, then the earlier
shape in the list above. Percentages are in tenths, rounded half up.

## Running it

| Platform | Smoke test (no device) | Real run |
|---|---|---|
| Apple | `cd ios/Tools/term-harness && swift run term-harness --fake` (or `--fake scripted`) | `swift run term-harness [--lang en,ja] [--out results.md]`. This uses Apple Translation on the Mac (the iOS 26 frameworks) and needs the language pairs installed: System Settings › General › Language & Region › Translation Languages. |
| Android | `cd android && node scripts/term-harness.mjs --translator fake` (or `scripted`) | `android/tool/term_harness.sh [--lang en,ja]` with the Note 9 connected. It runs ML Kit on the phone in `TermHarnessTest`, and the TS core masks and scores on the Mac. |

`--fake scripted` halves `[[`/`]]` and `__`. This makes those two shapes lose every placeholder, so the
table, the fallback path and the best-shape choice can all be checked without a translator.

`--write-packs` (off by default, real runs only) writes the best shape into
`shared/languages/<lang>.json`: `applePlaceholder` from the Swift harness, `androidPlaceholder` from
the Android one. ARCHITECTURE D2 chooses the shape per platform translator, so there is one key per
platform, mirroring `appleLocale`/`androidLocale`. The line goes after `"whisperCode"`, or replaces
the existing value. Afterwards, run `npm run sync-shared` in `android/` and both test suites. The pack
parsers ignore these keys until the app reads them.
