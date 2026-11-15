# Translation refine step

Apple Translation output is shown (and spoken) at once. Then the on-device Apple Intelligence model gets the source,
the draft, the last four lines of the conversation and the glossary terms found in the phrase, and its fix replaces
the line in place: screen, history (mirrors `ui.lines`) and, for my line, the board subtitle. Any failure keeps the
draft. Settings: "Sửa bản dịch bằng Apple Intelligence" (default on).

## FoundationModels: checked vs assumed

Checked in the iOS 26.4 SDK (Xcode 26.4.1, `FoundationModels.swiftinterface`):

- `SystemLanguageModel.default.availability`: `.available` or `.unavailable(.deviceNotEligible |
  .appleIntelligenceNotEnabled | .modelNotReady)`.
- `supportsLocale(_:)`, `supportedLanguages`; `contextSize` is 4096 tokens (instructions, prompt and reply together).
- `LanguageModelSession(model:instructions:)`, `respond(to:options:)`, `prewarm()`.
  `GenerationOptions(sampling: .greedy, maximumResponseTokens:)`.
- Errors: `GenerationError.guardrailViolation`, `.refusal`, `.unsupportedLanguageOrLocale`,
  `.exceededContextWindowSize`, `.rateLimited`, `.concurrentRequests`, `.assetsUnavailable`.
- `@Generable` / `@Guide` guided generation exists (iOS 26.0).

Measured on a Mac (Apple M5, macOS 26.3.1; assumed to be the same system model as on iPhone):

- Supported: vi, en, ja, ko, zh-Hans, fr, de, es (and da, it, nb, nl, pt, sv, tr, zh-Hant). **Thai is not**: the
  th pair never refines.
- Latency of one refine with the real prompt: 0.13 to 0.65 s, first call after prewarm included.
- Guided generation (a one-field `@Generable`) gave the same text as plain output and was slightly slower (schema in
  the prompt), so the step uses plain text with greedy sampling and validates the reply itself.
- Quality, 12 hand-made cases: fixed a wrongly translated place name (ga Thung lũng → ga Shibuya), a preposition
  (de→vi "tại" → "với"), a literal vi→en "I thank sister a lot" → "I thank you very much"; left most good drafts as
  they were. It also turned a correct Japanese "peanut" into "almond" (vi→ja); see Risks.

Assumed, to check on the iPhone 17 Pro: availability (Apple Intelligence on, model downloaded), latency (the Mac is
faster; expect about 0.5 to 1.5 s), and the language list matching the Mac's.

## Design

- `Sources/Core/TranslationRefiner.swift`: `RefineModel` protocol; `RefinePrompt` (instructions, prompt with
  context and required terms, context from `ui.lines`); `RefineCheck` (reply cleaning and checks);
  `TranslationRefiner` (supported pair, 2 s timeout that returns without waiting for the model); `RefineApply`
  (stale guard).
- `Sources/Engine/FoundationRefineModel.swift`: the FoundationModels model, under `#if canImport(FoundationModels)`.
  A fresh session per request, one kept prewarmed for the next; prewarmed when a supported pair starts running.
- Their line (X → vi): `ConversationController.refineTheirs`. The fix lands only if the line still shows the draft,
  was not corrected with "Sửa", and the pair did not change.
- My line (vi → X): `SubtitleTranslator` refines each final phrase off its queue (a slow model never holds the next
  phrase); the fix lands only if that phrase still shows the draft; `showSubtitle` updates the line and, for the
  current turn, the board.
- Terms: the same terms `TextPipeline` protects in the phrase (glossary, pack terms), with their fixed translation.

A reply is rejected (draft kept) when it is empty, several lines, longer than twice the draft (or draft + 24
characters), a copy of the source, in the wrong script (CJK/kana/Hangul/Thai into Vietnamese or a Latin language,
none of the target's script into ja/ko/zh/th, Vietnamese words into en/fr/de/es, unaccented English into
Vietnamese), drops a required term the draft had, or is too far from the draft (character-bigram similarity under
0.35).

## Speech

Their translation is spoken to me at once from the draft: waiting for the model would add 0.5 to 1.5 s before every
phrase. The speech chain reads the line's text when its turn to be spoken comes, so when earlier lines are still
being spoken, a fix that arrived meanwhile is the one said. My side is not spoken (board subtitle only), so nothing
waits there either.

## Risks

- The model is small (about 3B parameters per Apple; not visible in the SDK). It can replace a correct word with a wrong one; the similarity check
  catches rewrites, not a one-word change. The switch in Settings turns the step off.
- Lines change after they appear (a short flicker when a fix lands).
- Both directions can ask at the same time; the framework may serialize or rate-limit, which shows up as timeouts
  (draft kept).
