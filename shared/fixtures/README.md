# Shared test fixtures

The contract between the Swift core (`ios/Sources/Core`) and the TypeScript core
(`android/src/core`, `android/src/board`, `android/src/engine`). The cases were
taken from the Flutter reference tests in `app/test/**` (plus a few edge cases
added during the extraction); those tests now load these files and pass
against the Dart reference (`cd app && flutter test`). A port that cannot pass a case stops
and reports NEEDS_CONTEXT; it never edits a fixture. A new behaviour starts as a
new case here.

## Conventions

- Files are UTF-8 JSON. Strings are compared **exactly** (code point for code
  point; no trimming, no normalization by the loader). A few inputs are
  deliberately decomposed (NFD) or hold control, invisible or non-BMP
  characters; read them with a real JSON parser.
- Every case has a `name`, unique within its list; use it as the test name.
- `fontSets` is the board's bit mask as an integer: latinVI 1, latinExtA 2,
  cjk 4, hangul 8, thai 16. Code points are integers.
- Bytes are lower-case hex strings without separators (`"0300586e"`).
- Times are integers in milliseconds (`atMs`, `delayMs`, `...Ms`) from an
  arbitrary origin unless said otherwise.
- `null` in an `expected` field means the function returns nothing (`nil` /
  `null`), not "do not check". A field that is absent is not checked.
- Packs: `{"pack": "vi"}` or `{"file": "vi"}` means `shared/languages/vi.json`.
  An inline pack object is in the same JSON format as the files in
  `shared/languages` (parse it with the same parser).
- Terms are in the pack `terms` format: `{"id", "text", "variants"?, "fixed"?,
  "origin"?}`; `id` defaults to `text`, `variants` to `[]`, `fixed` to `{}`,
  `origin` to `"user"`.
- `shared/languages/*.json` and `shared/board_glyphs/*.txt` are byte-identical
  copies of `app/assets/languages` and `app/assets/board_glyphs`
  (`app/test/shared_assets_test.dart`).

| File | Module (Dart reference) | Dart test |
|---|---|---|
| `rules.json` | `app/lib/core/rule_engine.dart` (replaces Swift `VietnameseFixup`) | `app/test/core/rule_engine_test.dart` |
| `terms.json` | `term_protector.dart` | `term_protector_test.dart` |
| `text_pipeline.json` | `text_pipeline.dart` | `text_pipeline_test.dart` |
| `board_text.json` | `board_text.dart`, `translit.dart`, `board_glyphs.dart` | `board_text_test.dart` |
| `translit.json` (tables, not cases) | `translit.dart` | `translit_test.dart` |
| `glossary.json` | `glossary.dart` | `glossary_test.dart` |
| `language_catalog.json` | `language_catalog.dart` | `language_catalog_test.dart` |
| `model.json` | `model.dart` | `model_test.dart` |
| `conversation_activity.json` | `conversation_activity.dart` | `conversation_activity_test.dart` |
| `subtitle_translator.json` | `subtitle_translator.dart` | `subtitle_translator_test.dart` |
| `turn_assembler.json` + `*.jsonl` | `turn_assembler.dart` | `turn_assembler_test.dart` |
| `adpcm.json` | `app/lib/board/adpcm.dart` | `app/test/board/adpcm_test.dart` |
| `protocol.json` | `app/lib/board/protocol.dart` | `app/test/board/protocol_test.dart` |
| `session_machine.json` | `app/lib/engine/session_machine.dart` | `app/test/engine/session_machine_test.dart` |

---

## rules.json — RuleEngine

```
{
  "engines": { "<engineId>": Engine },
  "cases": [ { "name", "engine": engineId, "fn": "fixRecognition" | "forTranslation",
               "input": string, "expected": string } ],
  "adversarial": { "minLength": int, "maxMsPerRule": int, "maxMsPipeline": int,
                   "subjects": [ { "name", "unit": string, "prefix": string } ] },
  "portableSyntax": { "digits": "ascii", "lookbehind": "bounded",
                      "forbidden": [ { "name", "regex": string } ] }
}
Engine = { "pack": code }                                   // the pack's recognition + beforeTranslation rules
       | { "recognition": [Rule], "beforeTranslation": [Rule] }   // rules given inline
Rule   = { "id", "pattern", "template", "atClauseStart"?: bool (false), "context"?: string }
```

For each case build the engine and call `fn(input)`; the result must equal
`expected`. Every `VietnameseFixupTests` case of the Swift app is here with
engine `vi` (`fixLoanwords` → `fixRecognition`, `forTranslation` →
`forTranslation`). Engine rules, one per line:

- Input is NFC-normalized before any rule runs (one case is NFD).
- Rules run in list order, each as a replace-all over the result of the previous one.
- The pack pattern is wrapped as `(?:pattern)` first, then the bounds are added: `(?<![\p{L}\p{N}])(?:pattern)(?![\p{L}\p{N}])`.
- With `atClauseStart` the prefix is `(^|[,.!?])\s*` instead, and the template gets the punctuation back as `$1`.
- Matching is case-insensitive and Unicode (JS: flags `giu`; ICU: case-insensitive).
- `$n` in a template is capture group n (empty when the group did not take part or does not exist).
- `context`, when set, is a separate case-insensitive regex that must match somewhere in the whole text, or the rule does nothing.
- `forTranslation` = `fixRecognition`, then the beforeTranslation rules, then tidy: collapse whitespace runs to one space, drop spaces before `,.!?`, drop commas right after `,.!?`, drop leading spaces/`,`/`.`/`!`, trim the end, upper-case the first letter when the original input started upper-case.
- If no letter (`\p{L}`) is left after tidy, `forTranslation` returns the `fixRecognition` result instead.
- A pack with no recognition rules returns the input untouched (not even NFC); with no beforeTranslation rules, `forTranslation` returns `fixRecognition`'s result.

Regex dialect (`portableSyntax`). Pack patterns are written in the subset that
ICU (`NSRegularExpression`), JavaScript `RegExp` with the `u` flag (Hermes) and
Dart agree on; `rule_engine_test.dart` lints every pattern and context of every
`shared/languages/*.json` against it:

- `digits: "ascii"`: `\d` means `[0-9]` only. Dart and JS already do this; ICU and Swift `Regex` match every Unicode decimal digit, so the Swift port must make `\d` ASCII-only (e.g. rewrite `\d` to `[0-9]` outside character-class escapes before compiling, or Swift `Regex` with `.asciiOnlyDigits()`). Cases `dialect: …` check it (an Arabic-Indic or fullwidth digit is not a price).
- `lookbehind: "bounded"`: a lookbehind body has no `*`, `+` or `{n,}` (ICU rejects unbounded lookbehind); alternatives of different fixed lengths are fine.
- `forbidden`: none of these regexes may match a pattern: possessive quantifiers, atomic groups, inline flags, named groups and `\k<…>`, `\A \Z \z \G \h \H \R \X \K`, POSIX classes, `\p{…}` other than `\p{L}`, `\p{N}`, `\p{M}`.
- `\s` is left to each engine (Unicode whitespace in all three; packs only use it before punctuation or the end).

`adversarial` (timing, not exact output): build each subject as `prefix` +
`unit` repeated until its length is at least `minLength`; every compiled rule of
`shared/languages/vi.json` (with its context) must run a replace-all on each
subject in under `maxMsPerRule` ms, and `forTranslation` on each subject in
under `maxMsPipeline` ms.

## terms.json — TermProtector

```
{
  "defaultPlaceholder": "Zorvik{n}",
  "cases": [ { "name", "text": string, "terms": [Term], "target": languageCode,
               "placeholder"?: string,               // default defaultPlaceholder
               "masked"?: string, "isEmpty"?: bool,
               "restores"?: [ { "translated": string, "expected": string | null } ],
               "error"?: "invalidPlaceholder" } ]
}
```

Call `mask(text, terms, target, placeholder)`. With `error`, mask must throw an
argument error (placeholder without exactly one `{n}`, or nothing around it).
Otherwise its text must equal `masked`, and `isEmpty` (no term found) must
match when given. Then, for each `restores` entry, `restore(translated, masked)`
must return `expected` (`null` = restore fails: a placeholder lost, duplicated,
or invented). Behaviour (Review Focus 3), one rule per line:

- `mask` NFC-normalizes the text and every term/variant first; the masked text is NFC even when no term is found.
- Candidates are each term's `text` then its `variants`; empty ones are skipped; a surface already seen (after NFC, exact) is skipped, so a surface shared by two terms belongs to the first.
- Candidates are tried longest first, length in UTF-16 code units; equal lengths keep their input order.
- Each candidate is matched literally (all regex metacharacters escaped) at every position; a match overlapping an already masked span is skipped (never double-masked).
- Case: a candidate containing a non-Latin letter matches exactly (case-sensitive); otherwise case-insensitively, and the spoken form found in the text is what comes back.
- Word bounds only at edges that are letters or digits (`\p{L}\p{N}`): a bound `(?<![\p{L}\p{N}])` before when the first character is a letter/digit, `(?![\p{L}\p{N}])` after when the last one is, so `C++` matches before `+`, and `An` does not match in `Anh`.
- No bound at an edge whose character is in a script written without spaces: U+0E00–U+0E7F, U+1100–U+11FF, U+3040–U+30FF, U+3130–U+318F, U+3400–U+4DBF, U+4E00–U+9FFF, U+AC00–U+D7A3, U+F900–U+FAFF.
- Placeholder = prefix + n + suffix from the shape (`{n}` exactly once, some text around it, else an argument error).
- Numbers are 1, 2, … in order of appearance in the text, skipping every number the source text already shows in that shape (matched case-insensitively).
- One number per (term with a fixed translation for the target), else per distinct spoken form; the number turns back into the fixed translation, or the spoken form when the term has none for the target.
- `restore` on a mask that found nothing returns the input unchanged.
- `restore` finds placeholders case-insensitively, replaces each with its output, and does not rescan the result.
- `restore` returns null when a number we issued appears a different number of times than in the masked text, or a number we did not issue (and the source did not contain) appears.

## text_pipeline.json — TextPipeline

```
{
  "defaultPlaceholder": "Zorvik{n}",
  "packs": { "<packId>": {"file": code} | InlinePack },
  "prepare":   [ { "name", "home": packId, "other": packId, "direction": "mine" | "theirs",
                   "glossary"?: [Term], "placeholders"?: { languageCode: placeholder },
                   "input": string, "prepared": string,
                   "finish"?: [ { "translated": string, "expected": string | null } ] } ],
  "translate": [ { ...same pipeline fields..., "input": string,
                   "responses": [string], "requests": [string],
                   "expected": string, "lostPlaceholders": int } ]
}
```

Build `TextPipeline(home, other, glossary, placeholders, defaultPlaceholder)`.
`mine` translates home → other (home pack rules, target = other code); `theirs`
other → home (other pack rules, target = home code). Terms are glossary first,
then home pack terms, then other pack terms (the glossary wins over a built-in
term spelled the same).

- `prepare`: `prepare(input, direction).text` must equal `prepared`; each
  `finish` entry: `finish(translated, prepared)` must equal `expected`.
- `translate`: call `translate(input, direction, translator)` with a fake
  translator that records each request and returns `responses[i]` for the i-th
  call. The recorded requests must equal `requests`, the result `expected`, and
  the pipeline's lost-placeholder counter `lostPlaceholders`. A lost
  placeholder makes the pipeline translate the unmasked text and repair fixed
  terms (whole words, same case).

## board_text.json — BoardText, transliteration, glyph lists

Unless a case has `glyphs`, the CJK/Hangul/Thai lists are
`shared/board_glyphs/{cjk,hangul,thai}.txt` (one `XXXX` or `XXXX-YYYY` hex per
line). `glyphs` = `{ "cjk": [[lo, hi]], "hangul": [...], "thai": [...] }`
replaces them for that case.

```
{
  "ranges":     [ { "name", "fontSets", "glyphs"?,
                    "expected"?: [[lo, hi]],   // the whole merged, sorted list
                    "sameAs"?: fontSets,        // equal to ranges(sameAs)
                    "expectedLast"?: [lo, hi],  // last range
                    "noneFrom"?: codePoint } ], // no range starts at or above it
  "isDrawable": [ { "name", "codePoint", "fontSets", "glyphs"?, "expected": bool } ],
  "parseRanges":[ { "name", "input": string, "expected"?: [[lo, hi]], "error"?: true } ],
  "encode":     [ { "name", "input": string, "fontSets", "expected": string } ],
  "encodeInvariants": { "samples": [string], "fontSets": [int] }
}
```

- `ranges(fontSets)`: Latin/Vietnamese ranges always (a board reporting no Latin
  bit counts as latinVI), Latin Extended-A U+0100–U+017F with bit 2, then the
  listed code points of each extra font whose bit is set; sorted, overlapping
  ranges merged.
- `parseRanges(text)`: blank lines and `#` comments skipped; anything else that
  is not hex or a reversed range is an error.
- `encode(input, fontSets)` must equal `expected`. The tables named below are
  in `translit.json` (exported from `translit.dart`, the source of truth). The
  algorithm, one step per line:
  - NFC the input.
  - Split it into words on runs of `[\s\u0000-\u001f\u007f-\u009f   ]`; encode each word; drop words that encode to `""`; join with one space; collapse runs of spaces; trim.
  - Result empty: `""` if the NFC input was blank, else `·`.
  - Per word, first a compatibility fold: each code point that is not drawable, has no letter table, is not kana, is not a `punctuation` key, not a `latinSpecial` key, not an other-script digit and cannot be mark-folded is replaced by its NFKC form (fullwidth `Ａ` → `A`, `ﬁ` → `fi`, `①` → `1`).
  - All-caps word: at least two code points have a letter table (cyrillic/greek) and all of those are upper-case.
  - Then per code point, first rule that applies:
  - drawable with `fontSets` (see `ranges`) → kept;
  - Cyrillic/Greek letter → its `cyrillic`/`greek` value (via lower case); a capital gives a capital first letter, or all capitals in an all-caps word; `υ`/`ύ` right after `ο`/`ό` (either case) gives `u`;
  - kana (`kana.isKana`) → romaji by the `kana` rules below; an unreadable kana gives `·`;
  - `punctuation` value, else `latinSpecial` value, else ASCII digit for a digit of another script (`digitZeros`: zero code points, each followed by 1–9), else the letter with its marks removed (NFD, drop `\p{M}`) when that differs and is drawable;
  - a single mark or invisible (`\p{M}`, `\p{C}`) → dropped;
  - any other letter or number (`\p{L}\p{N}`) → `·`, but not twice in a row;
  - anything else (symbols, emoji, other punctuation) → dropped.
- `encodeInvariants`: for every sample × every fontSets, `encode` is not empty,
  every character is a space or drawable with those sets, there is no leading
  or trailing space and no double space.

## translit.json — transliteration and folding tables

Data, not cases: the tables of `app/lib/core/translit.dart` (the source of
truth; `app/test/core/translit_test.dart` probes the Dart functions over whole
Unicode blocks and fails if the export differs). Ports load these tables
instead of copying them; `board_text.json` checks the result.

```
{
  "cyrillic": { lowerCaseLetter: latin },  "greek": { lowerCaseLetter: latin },
  "capitals": { "cases": [ { "letter", "allCaps": bool, "expected" } ] },
  "upsilonAfterOmicron": { "letters": ["υ","ύ"], "latin": "u", "omicrons": [...] },
  "latinSpecial": { char: ascii },          // letters with no decomposition: ł→l, ß→ss, đ→d …
  "punctuation": { char: spelling },        // may contain a space ("、" → ", ")
  "digitZeros": [codePoint],                // U+0660, U+06F0, U+0966, U+09E6, U+0E50
  "kana": { "hiraganaRange", "katakanaRange", "katakanaOffset": 96, "hiragana": { kana: romaji },
            "smallY": { "ゃ": "a", "ゅ": "u", "ょ": "o" }, "sokuon": "っ", "n": "ん",
            "nApostropheBefore": [kana], "silent": [char], "isKana": [[lo, hi]] }
}
```

Rules, one per line:

- A Cyrillic/Greek letter is looked up by its lower case; an empty value (`ъ`, `ь`) gives nothing.
- A capital gives its value with the first letter upper-cased, or all upper-case when the word is all-caps (`capitals.cases`).
- `υ`/`ύ` directly after an omicron (`omicrons`) gives `u` (the diphthong `ου`).
- Katakana in `katakanaRange` reads as the hiragana `katakanaOffset` below it.
- `silent` characters (long-vowel mark, iteration marks) give nothing.
- `sokuon` reads the next kana: nothing if there is none; the next kana unchanged if its romaji starts with a vowel or `n`; else its first consonant doubled (`t` before `ch`) + its romaji.
- `n` gives `n'` when the next kana (as hiragana) is in `nApostropheBefore`, else `n`.
- A small `ゃゅょ` alone gives `y` + its vowel.
- A hiragana whose romaji has two or more letters and ends in `i`, followed by a small `ゃゅょ`: drop the `i`; stems `sh`, `ch`, `j` add the vowel, others add `y` + vowel (`きょ` → `kyo`, `しゃ` → `sha`); both kana are used.
- Any other code point in `isKana` with no `hiragana` entry is unreadable (BoardText gives `·`).

## glossary.json — glossary validation

```
{
  "limits": { "maxTerms": 500, "maxLength": 64, "maxVariants": 8 },
  "cases": [ { "name", "existing"?: [Input], "op": "add" | "update" | "remove",
               "input"?: Input, "target"?: int, "targetId"?: string,
               "expect": { "ok": true, "text"?, "variants"?, "fixed"?, "allTexts"?: [string] }
                       | { "error": ErrorName, "field"?, "limit"?, "codePoint"?, "value"? } } ],
  "load":  [ { "name", "content": string, "recovered": bool, "texts"?: [string] } ]
}
Input     = { "text": string, "variants"?: [string], "fixed"?: { code: string } }
ErrorName = "EmptyText" | "TooLong" | "TooManyVariants" | "TooManyTerms"
          | "ForbiddenCharacter" | "DuplicateTerm" | "UnknownTerm"
```

Each case starts from an empty store and adds every `existing` input in order
(all valid). Then:

- `add` adds `input`; `update` replaces the term `existing[target]` (or the id
  `targetId`, which does not exist) with `input`; `remove` deletes it.
- `ok`: the returned term has `text` (trimmed), `variants`, `fixed` as given,
  origin user; `allTexts` is the texts of every term in order afterwards.
- `error`: the change is refused with that error, carrying `field`
  (`text`, `variants[i]`, `fixed.<code>`, or `fixed` for an empty code),
  `limit`, `codePoint` and the offending `value` when given; the list and the
  stored data are unchanged.

Rules: every string trimmed and non-empty; at most 64 characters (Unicode
scalars, not UTF-16 units; one case uses U+1D400); no U+0000–U+001F,
U+007F–U+009F, U+202A–U+202E, U+2066–U+2069; at most 8 variants and 500 terms;
text and variants unique across the glossary ignoring case (NFC + lower case),
a term's own old text excluded on update.

`load`: the stored glossary (a JSON list of terms in the pack term format)
holds `content`. Opening the store must give the terms `texts` (absent = none)
and set the "recovered from corruption" flag to `recovered`: invalid JSON, not a
list, a bad entry, an entry over the limits or duplicates all recover to an
empty glossary. (Where the bad data goes is platform-specific; the Dart store
renames the file aside.)

## language_catalog.json — LanguageCatalog

```
{
  "homeCode": "vi", "platforms": ["ios", "android"], "invalidPlatforms": [string],
  "chainOrder": ["osOnDevice", "whisper", "osOnline"],
  "packs": [ { "code", "label" } ],
  "offered": [ { "name", "packs"?: [ {code, label} ], "caps": Caps, "platform",
                 "consent"?: [code], "expected": [code] } ],
  "chain":   [ { "name", "caps": Caps, "platform", "consent"?: [code], "code", "expected": [RecognizerKind] } ]
}
Caps = { "recognizers": { code: [RecognizerKind] }, "translatable": [code] }
```

Build the catalog from `packs` (or the case's own `packs`), the capabilities,
the platform and the online consent set. `offered` lists the codes in order;
`chain(code)` the recognizer kinds in order. Rules: Vietnamese (`homeCode`) is
never offered; a pack is offered when it is translatable and its chain is not
empty; the chain is the kinds the device has, in `chainOrder`, with `osOnline`
only on Android and only for a consented language; offered packs are sorted by
`label` lower-cased (UTF-16 code unit order), ties by `code`. Constructing with
a platform in `invalidPlatforms` must fail.

## model.json — language pack JSON and FontSets

```
{
  "scripts": [string], "recognizerKinds": [string], "fontSetBits": { name: int },
  "shippedPacks": { code: { "code", "appleLocale", "androidLocale", "whisperCode", "label",
                            "labelLatin", "script", "minConfidence": number | null,
                            "hasRecognition": bool, "hasBeforeTranslation": bool,
                            "termCount": int, "hintCount": int } },
  "packOk":     [ { "name", "base": code, "set"?: {field: value}, "remove"?: [field],
                    "expect": { "script"?, "recognitionCount"?, "atClauseStart"?,
                                "termOrigin"?, "hints"?, "minConfidence"? } } ],
  "packErrors": [ { "name", "base": code, "set"?, "remove"?, "field": string } ],
  "covers":     [ { "name", "fontSets", "script", "expected": bool } ]
}
```

- `shippedPacks`: parsing `shared/languages/<code>.json` gives those values.
- `packOk` / `packErrors`: take `shared/languages/<base>.json` as an object,
  delete the `remove` keys, set the `set` keys, serialize and parse. `packOk`
  parses with the listed values (`atClauseStart` of the first recognition rule,
  `termOrigin` of the single term); `packErrors` fails with a pack error whose
  field path is `field` (`label`, `recognition[0].pattern`, `terms[0].fixed`,
  …). Patterns and contexts that do not compile as Unicode regexes are errors.
- `covers`: `FontSets(fontSets).covers(script)`. Latin needs bit 1 or 2;
  cyrillic and other are never covered. (0 covers nothing here; BoardText
  separately treats a board reporting 0 as latinVI.)

## conversation_activity.json — ConversationActivity

```
{
  "defaults": { "idleTimeoutMs": 600000, "retryDelayMs": 30000 },
  "events": [ActivityEvent],
  "scenarios": [ { "name", "config"?: { "idleTimeoutMs"?, "retryDelayMs"? },
                   "steps": [ { "event": ActivityEvent, "atMs": int, "expect": "start" | "stop" | null, "state"?: "idle" | "active" }
                            | { "startFailed": true, "atMs": int, "state"?: ... } ] } ]
}
```

A fresh machine (idle) per scenario with the config over the defaults. For an
event step, `handle(event, t0 + atMs)` must return the transition `expect`
(`null` = no transition). A `startFailed` step calls `startFailed(t0 + atMs)`.
After a step with `state`, the state must be that. `atMs` is not always
increasing within a scenario; pass it through as given.

Rules, one per line (state: idle/active, lastSpeech, gateOpen, speaking, noAutoStartUntil; all start idle / past / false / false / past):

- `boardAudio`, `gateOpen`, `ttsStart`, `userStart` are "speech": lastSpeech = now; then if idle and now ≥ noAutoStartUntil → active, return `start`; otherwise nothing.
- `gateOpen` also sets gateOpen; `ttsStart` sets speaking; `userStart` first clears the hold-off (noAutoStartUntil = past), so a tap always starts.
- `gateClosed` / `ttsEnd` clear gateOpen / speaking and, only while active, set lastSpeech = now (the timeout counts from when speech ended); never a transition.
- `tick` returns `stop` (→ idle) only when active, the gate is closed, nothing is being spoken, and now − lastSpeech ≥ idleTimeout.
- `stop` clears gateOpen and speaking; returns `stop` (→ idle) only if it was active.
- `userStop` is `stop` plus a latch: noAutoStartUntil = forever, so board audio, gate and TTS cannot start a conversation until the next `userStart`.
- `startFailed(now)`: back to idle with no transition, flags cleared, noAutoStartUntil = now + retryDelay (automatic events are ignored until then; a tap retries at once).

## subtitle_translator.json — SubtitleTranslator

```
{
  "scenarios": [ { "name", "translator": { "delayMs": int, "failing"?: [string] },
                   "steps": [ { "op": "partial" | "final", "turn": int, "text": string }
                            | { "op": "reset" } | { "op": "wait", "ms": int } ],
                   "expect": { "results"?: { "<turn>": string },
                               "emptyTurns"?: [turn],
                               "requestCounts"?: [ { "text", "exactly"?: int, "max"?: int } ],
                               "maxRequestLength"?: int,
                               "wordCounts"?: { "<turn>": int } } } ]
}
```

The fake translator records every request, waits `delayMs`, then throws for a
text in `failing`, else returns the text upper-cased (`toUpperCase`). `partial`
→ `setPartial(text, turn)`, `final` → `addFinal(text, turn)`, `reset` →
`reset()`, `wait` → advance time by `ms` (real or fake timers) and let pending
work run. Steps between two waits are one synchronous burst. Afterwards:
`results` = the last text `onResult` gave for each turn; `emptyTurns` = turns
with no result or an empty one; `requestCounts` = how many requests equal
`text`; `maxRequestLength` = no request longer (UTF-16 length); `wordCounts` =
words (split on spaces, empties dropped) of a turn's last result.

Rules, one per line:

- A turn's text = the translations of its finals in order, then the current partial translation, empty parts skipped, joined by one space; every change is reported through `onResult(turn, text)`.
- `addFinal(text, turn)`: appends a final slot whose placeholder is the turn's current partial translation; clears the partial (source and translation) and drops a pending partial request of that turn.
- `addFinal` with empty text: the slot is final with `""` at once and `onResult` fires; nothing is translated.
- Non-empty finals are queued and translated one at a time, oldest first, each exactly once.
- A failed final translation keeps the placeholder (the partial translation it had).
- After `addFinal(…, turn)` only turns greater than `turn − 3` are kept; late results for dropped turns are discarded.
- `setPartial(text, turn)` with the same text as the turn's current partial source does nothing.
- `setPartial` with empty text clears the partial translation, drops the pending partial request and fires `onResult`.
- Partials are latest-wins: one pending partial request across all turns; a newer `setPartial` replaces it.
- Queued finals always go before the pending partial.
- A partial translation is applied only if it succeeded and the turn's partial source is still that text (not changed, not finalized).
- Work starts after the caller's synchronous burst (the next microtask / task), not inside `setPartial`/`addFinal`.
- `reset()` drops every turn, queued final and pending partial; translations already in flight are discarded when they return.

## turn_assembler.json — TurnAssembler (+ the two recordings)

```
{
  "defaults": { "turnGapMs": 2000, "staleGapMs": 10000, "maxCharacters": 600, "maxDurationMs": 60000 },
  "scenarios": [ { "name", "config"?: { ...defaults keys..., "fixLoanwords"?: packCode },
                   "steps": [ { "kind": "partial" | "final", "text", "atMs",
                                "change"?: null | { "started": bool, "finalText": string | null },
                                "turnText"?: string }
                            | { "kind": "reset", "turnIsNull"?: true } ],
                   "maxTurnTextLength"?: int, "minDistinctTurns"?: int } ],
  "replays": [ { "name", "recording": file, "config"?, "expectLines": [string] } ]
}
```

`fixLoanwords: "vi"` = the vi pack's `fixRecognition` applied to each event's
text (absent: identity). Each step calls `handle(event, t0 + atMs)`; `change`
(when present) must equal the returned change (`null` = nothing changed);
`turnText` is the current turn's text afterwards; `turnIsNull` after reset.
`maxTurnTextLength` holds after every step; `minDistinctTurns` = the number of
different turn ids seen.

Replays: `shared/fixtures/<recording>` is JSON Lines of
`{"t": seconds (float), "kind": "partial" | "final", "text"}` (recorded from
the iOS recognizer, vi-VN). Feed every event at `t0 + t`; after each event
that returns a change while a turn exists, remember `turn.text` for `turn.id`.
The texts per turn id, in first-seen order, must equal `expectLines`.

Rules, one per line (quiet = now − time of the previous non-empty event; "greater" is strict):

- The event text is trimmed, then `fixLoanwords` is applied.
- Empty text: if the turn has a partial, clear it and return a change `{started: false, finalText: null}`; else return null (nothing changed). Empty events do not update the previous-event time.
- A new turn starts (fresh id, ids 1, 2, … never reused, also across `reset`) when: there is no turn; or this is the first event ever; or quiet > staleGap; or the turn has no partial and (quiet > turnGap or the turn was closed by the cap).
- So while a partial is pending the turn never splits on turnGap, only after staleGap.
- Partial: replaces the turn's partial. Final: appended to the turn's finals, partial cleared, `finalText` = the text.
- Cap: after a final, the turn is closed when its text is longer than maxCharacters **grapheme clusters** (Dart `characters.length`, not UTF-16 units) or now − turn start > maxDuration; the next non-empty event then starts a new turn.
- The returned change is `{started, finalText}` for every non-empty event.
- `reset()` forgets the turn and the cap flag (the previous-event time is kept).
- Turn text = finals then partial, empty parts skipped, joined by one space.

## adpcm.json — ADPCM decoder

```
{
  "maxGapPackets": 10, "stepTable": [89 ints], "indexTable": [16 ints],
  "sequences": [ { "name", "steps": [ { "packet": hex, "expected": [int16] } | { "reset": true } ] } ]
}
```

One decoder per sequence. `decode(packet)` must return exactly `expected`.
Packet: `[seq u16 LE][predictor i16 LE][index u8][data, low nibble first]`; 5
bytes or fewer decode to nothing; an index above 88 is treated as 88; the
predictor clamps to int16; after 1–10 lost packets (by 16-bit wrapping sequence
number) that many packets of silence (same sample count as this packet) come
first; `reset` forgets the last sequence number. The last sequence is the
firmware encoder (`firmware/main/adpcm.c`) round trip.

## protocol.json — board BLE protocol

```
{
  "uuids": { "service", "audio", "text", "control", "info" },
  "textKinds": { "subtitle": 0, "status": 1, "time": 2, "label": 3 },
  "maxTextBytes": 150, "maxLabelBytes": 32,
  "frameText": [ { "name", "text", "kind": textKindName, "maxWrite": int, "expected": [hex] } ],
  "labelText": [ { "name", "input", "expected" } ],
  "boardInfo": [ { "name", "hex", "expected": { "protocolVersion": int, "fontSets": int } | null } ],
  "timeText":  [ { "name", "epochMs": int, "utcOffsetMinutes": int, "expected": string } ]
}
```

- `frameText(text, kind, maxWrite)` must give exactly the chunks in `expected`:
  text over 150 UTF-8 bytes keeps its tail (whole grapheme clusters), drops the
  partial first word up to the first space and is prefixed with `…`; chunk
  payload = `max(20, maxWrite) - 2`; chunk = `[flags][kind][payload]`, flags
  bit0 first, bit1 last; always at least one chunk.
- `labelText(input)` keeps whole characters up to 32 UTF-8 bytes, no ellipsis.
- `boardInfo`: parsing the `…0005` value `[version u8][fontSets u32 LE]`;
  fewer than 5 bytes → null; extra bytes ignored.
- `timeText`: `"<unix seconds> <UTC offset minutes>"` for that instant seen
  at that UTC offset (whole seconds, milliseconds dropped; the offset is signed
  minutes, e.g. `420`, `-300`, `330`). Ports take the offset from the phone's
  time zone at that instant.

## session_machine.json — session state machine

```
{
  "missingKinds": ["speechModel", "translation", "ttsVoice"],
  "transitions": [ { "name", "state": State, "event": Event, "expected": State } ],
  "matrix":      [ { "name", "state": State, "event": Event, "expected": State } ],   // 9 x 10 = 90 cells
  "generations": [ { "name", "start": { "state": State, "generation": int },
                     "steps": [ { "event": Event, "state": State, "generation": int } ] } ]
}
State = {"type":"loading"} | {"type":"choosing","reason": string|null}
      | {"type":"checking","code"} | {"type":"needsDownload","code","missing":[Missing],"error": string|null}
      | {"type":"downloading","code"} | {"type":"preparing","code","restarts":int}
      | {"type":"running","code","restarts":int} | {"type":"switching","from","to"}
      | {"type":"failed","code","reason"}
Event = {"type":"catalogReady","saved": string|null,"offered":[code]} | {"type":"picked","code"}
      | {"type":"checked","missing":[Missing]} | {"type":"downloadTapped"} | {"type":"downloadDone"}
      | {"type":"downloadFailed","error"} | {"type":"started"} | {"type":"startFailed","reason"}
      | {"type":"recognizerDied"} | {"type":"retry"}
Missing = { "kind": missingKind, "language": code, "from"?: code, "to"?: code }
```

`next(state, event)` must equal `expected` (value equality, `missing` compared
element by element), for every case of `transitions` (hand-picked, incl.
variants such as `restarts: 1` or a saved language that is not offered) and of
`matrix`. `matrix` is the full table: every state type × every event type with
representative values, generated from the Dart machine by
`app/test/engine/session_matrix_generator.dart` (run it with `flutter test` on
that file after changing the machine) and asserted by `session_machine_test.dart`,
which also checks that all 90 pairs are present.

The transition table (these 14 pairs change the state; **every other pair
leaves the state unchanged**, e.g. preparing + picked, checking + picked,
downloading + picked, running + downloadDone, loading + started):

| State | Event | Next |
|---|---|---|
| loading | catalogReady(saved, offered) | no saved → choosing(reason null); saved in offered → checking(saved); else → choosing(reason "unavailable") |
| choosing | picked(c) | checking(c) |
| needsDownload | picked(c) | checking(c) |
| failed | picked(c) | checking(c) |
| checking(c) | checked(missing) | empty → preparing(c, restarts 0); else → needsDownload(c, missing, error null) |
| needsDownload(c) | downloadTapped | downloading(c) |
| downloading(c) | downloadDone | checking(c) (re-check: one download may not cover everything) |
| downloading(c) | downloadFailed(e) | needsDownload(c, [], error e) |
| preparing(c, r) | started | running(c, r) |
| preparing(c) | startFailed(reason) | failed(c, reason) |
| running(c) | picked(y) | y = c → unchanged; else → switching(c, y) |
| running(c, r) | recognizerDied | r = 0 → preparing(c, restarts 1); else → failed(c, "recognizer stopped") |
| switching(from, to) | checked(missing) | empty → preparing(to, 0); else → needsDownload(to, missing) |
| failed(c) | retry | checking(c) |

`generations`: starting from `start`, each
`advance(session, event)` must give that state and generation; the generation
goes up by one only when the new state is a `switching` different from the old
state.

---

## Not fixture-driven (stay in Dart, ports write their own)

| Test | Why |
|---|---|
| `rule_engine_test`: every bundled rule has a unique id; the adversarial timing loop; the portable-syntax lint | properties of the pack data; a clock measurement (subjects, limits and the forbidden list are in `rules.json`) |
| `translit_test` | proves `translit.json` equals `translit.dart`; ports load the tables, `board_text.json` checks them |
| `session_matrix_generator.dart` | writes the `matrix` of `session_machine.json` from the Dart machine; not part of the suite |
| `text_pipeline_test`: a translator error propagates | exception thrown by the injected fake |
| `board_text_test`: Latin ranges equal `firmware/main/glyphs.c` | reads firmware source the apps do not ship |
| `board_glyphs_test` (whole file) | Flutter asset loading (`rootBundle`) and the shared-instance assertion |
| `glossary_test`: file round trip, change stream, read-only list, atomic write, parent directory, two corrupt files in one second, not-UTF-8 bytes, concurrent changes, write failure | storage, streams, timers and file-system errors are platform code |
| `language_catalog_test`: offered/chain are read-only | Dart list immutability |
| `model_test`: `|`/contains/equality, Capabilities and BoardInfo equality, `toJson` round trip | Dart value types |
| `turn_assembler_test`: Turn equality | Dart value type |
| `session_machine_test`: value equality | Dart value types |
| `protocol_test`: `timeFrame` in local time | depends on the machine's time zone (UTC case is in `protocol.json`) |
| `adpcm_test`: the Dart port of the firmware encoder | proves the fixture vector; the ports only need the vector |
| `ble_board_link_test`, `fake_board_link_test`, `fake_voice_engine_test`, `app/test/ui/**`, `widget_test` | BLE link with fake adapter and timers, engine fakes, widgets and goldens |
