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
                   "subjects": [ { "name", "unit": string, "prefix": string } ] }
}
Engine = { "pack": code }                                   // the pack's recognition + beforeTranslation rules
       | { "recognition": [Rule], "beforeTranslation": [Rule] }   // rules given inline
Rule   = { "id", "pattern", "template", "atClauseStart"?: bool (false), "context"?: string }
```

For each case build the engine and call `fn(input)`; the result must equal
`expected`. Every `VietnameseFixupTests` case of the Swift app is here with
engine `vi` (`fixLoanwords` → `fixRecognition`, `forTranslation` →
`forTranslation`). Engine rules a port must implement to pass:

- input is NFC-normalized before any rule runs (one case is NFD);
- patterns are case-insensitive, Unicode, and whole-word: the engine adds
  `(?<![\p{L}\p{N}])` before and `(?![\p{L}\p{N}])` after the pack pattern;
  with `atClauseStart` the prefix is `(^|[,.!?])\s*` and the template gets the
  punctuation back as `$1`; `$n` in a template is group n (empty if absent);
- `context`, when set, must match somewhere in the whole text or the rule does
  nothing;
- `forTranslation` = `fixRecognition`, then the beforeTranslation rules, then
  tidy (collapse spaces, drop spaces before `,.!?`, drop commas after
  punctuation, drop leading `space , . !`, trim the end, upper-case the first
  letter if the original started upper-case); if no letter is left, return the
  `fixRecognition` result instead. A pack without rules returns the input
  untouched (not even NFC).

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
or invented). Behaviour (Review Focus 3): terms and variants matched literally,
longest first, never double-masked; Latin case-insensitive (the spoken form
comes back), other scripts exact; whole words except in CJK/kana/Hangul/Thai;
placeholders numbered 1, 2, … in order of appearance, skipping numbers the text
already contains; one number per fixed translation of a term or per distinct
spoken form; placeholders matched case-insensitively on restore.

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
- `encode(input, fontSets)` must equal `expected`: NFC first; whitespace and
  controls collapse to one space, trimmed; drawable characters kept; Latin
  folded, Cyrillic/Greek/kana transliterated, symbols spelled; each run of
  undrawable letters becomes one `·`; blank input gives `""`.
- `encodeInvariants`: for every sample × every fontSets, `encode` is not empty,
  every character is a space or drawable with those sets, there is no leading
  or trailing space and no double space.

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
- `timeText`: `"<unix seconds> <UTC offset minutes>"` for that instant and
  offset (whole seconds, milliseconds dropped).

## session_machine.json — session state machine

```
{
  "missingKinds": ["speechModel", "translation", "ttsVoice"],
  "transitions": [ { "name", "state": State, "event": Event, "expected": State } ],
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
element by element). Events not listed for a state leave it unchanged (cases
named `unlisted: …`). `generations`: starting from `start`, each
`advance(session, event)` must give that state and generation; the generation
goes up by one only when the new state is a `switching` different from the old
state.

---

## Not fixture-driven (stay in Dart, ports write their own)

| Test | Why |
|---|---|
| `rule_engine_test`: every bundled rule has a unique id; the adversarial timing loop | a property of the pack data; a clock measurement (subjects and limits are in `rules.json`) |
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
