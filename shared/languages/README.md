# Language packs

One JSON file per language, parsed by the iPhone app (`ios/Sources/Core/Model.swift`)
and bundled as a folder reference (`ios/project.yml`). The schema is in
`shared/fixtures/README.md` (model.json, rules.json).

The schema has no `names`, `placeholder` or `notes` field: the Vietnamese display
name of a language and the `Zorvik{n}` placeholder shape live in the app (copy
and settings), so the packs carry only `label` (the language's own name) and
`labelLatin`.

## Starter packs (R14, P2.7)

`ja`, `ko`, `zh-Hans`, `th`, `fr`, `de`, `es`. `script`: ja and zh-Hans `cjk`,
ko `hangul`, th `thai`, fr/de/es `latin`. `minConfidence` is `null` (no
per-language threshold known). `zh-Hans` uses the Apple locale `zh-CN`.

### Terms (all seven packs)

`brand.*` terms with `origin: builtIn` protect brand names and loanwords from the
translator and restore them as the same Latin spelling for every target
(`fixed` lists all nine codes): Grab, Shopee, iPhone, Wi-Fi (variants `wifi`,
`wi fi`), Google Maps, ATM, Zalo, Facebook. ja, ko and th add the usual native
script spellings as variants (katakana, hangul, Thai); zh-Hans adds the official
Chinese names 虾皮 (Shopee), 谷歌地图 (Google Maps), 脸书 (Facebook).

Deliberately not included: `visa`, `taxi`, `hotel`. They are ordinary nouns in
every pack language (a visa document, a cab, a hotel) and translate correctly;
masking them would break that.

### Recognition rules

Only fr, de and es have rules (`loan.wifi`, `loan.iphone`, `loan.google-maps`,
`loan.shopee`): spellings a speech recognizer produces for the brand
(`ouifi`, `wai fai`, `güifi`, `aifon`, `gugle maps`, `shopi`). `grab` is not
fixed in German (it is the word for "grave").

ja, ko, zh-Hans and th have none: rule matches are word-bounded with
`\p{L}\p{N}` lookarounds, and these scripts attach particles and neighbours
directly to the word, so a bounded rule would almost never match. Their terms
(which are not bounded at CJK/Hangul/Thai edges) do the work instead. Known
limit: a Latin term such as `Grab` glued to CJK text (`我用Grab`) is not
matched, because the neighbouring character is a letter.

### beforeTranslation rules

None. vi.json's vocative and service-phrase rules fix Vietnamese forms of
address that the translator misreads; no equivalent in these languages is
known to be both common and wrong in translation, and fewer correct rules beat
doubtful ones. Add them here, with fixture cases, when a real failure is found.

All patterns stay in the portable regex subset (`rules.json` `portableSyntax`).
