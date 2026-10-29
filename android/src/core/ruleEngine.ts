// Port of app/lib/core/rule_engine.dart. Contract: shared/fixtures/rules.json
// (shared/fixtures/README.md, "rules.json — RuleEngine").
//
// Regex dialect: pack patterns are compiled as JS `RegExp` with the `u` flag (Hermes on the
// phone, V8 under Jest), case-insensitive. `\d` is ASCII-only in JS even with `u` (the portable
// dialect's `digits: "ascii"`), so it needs no rewriting here, unlike ICU on iOS. Input is
// NFC-normalized with `String.prototype.normalize` before the rules run.
import type {LanguagePack, Rule} from './model';

/** A `Rule` with its regular expressions compiled. */
export class CompiledRule {
  readonly id: string;
  /** The bounded pattern, global (replace-all). */
  readonly regex: RegExp;
  readonly template: string;
  /** The rule applies only when the whole text also matches this (e.g. talk about a price). */
  readonly context: RegExp | null;

  constructor(rule: Rule) {
    // Whole words only: no letter or digit may touch the match. The patterns in the pack data
    // stay free of bounds; the engine adds them. With `atClauseStart` the match must begin the
    // text or follow , . ! ? (the template gets the punctuation back as $1).
    const start = rule.atClauseStart ? '(^|[,.!?])\\s*' : '(?<![\\p{L}\\p{N}])';
    this.id = rule.id;
    this.regex = new RegExp(`${start}(?:${rule.pattern})(?![\\p{L}\\p{N}])`, 'giu');
    this.template = rule.template;
    this.context = rule.context === undefined ? null : new RegExp(rule.context, 'iu');
  }

  /** Applies the rule to `text` (replace-all). */
  apply(text: string): string {
    if (this.context !== null && !this.context.test(text)) {
      return text;
    }
    return text.replace(this.regex, (...args: unknown[]) => {
      // args = match, group 1..n, offset, whole string[, named groups object]
      const groupsEnd = typeof args[args.length - 1] === 'object' ? args.length - 3 : args.length - 2;
      const groups = args.slice(1, groupsEnd) as (string | undefined)[];
      return this.template.replace(/\$(\d)/g, (_, digit: string) => {
        const n = Number(digit);
        return n >= 1 && n <= groups.length ? groups[n - 1] ?? '' : '';
      });
    });
  }
}

/**
 * Applies a language pack's rules, which are data, to text around the recognizer and the
 * translator. Two lists, both whole-word and case-insensitive:
 * - `recognition` rules fix what the recognizer mishears (loanwords and brand names it spells as
 *   native syllables). Applied to the recognized text itself (`fixRecognition`: shown and
 *   translated).
 * - `beforeTranslation` rules rewrite text only for the translator (`forTranslation`): vocatives
 *   dropped, service phrases and idioms put in plain words. Never shown.
 */
export class RuleEngine {
  readonly recognitionRules: readonly CompiledRule[];
  readonly beforeRules: readonly CompiledRule[];

  constructor(recognition: readonly Rule[], beforeTranslation: readonly Rule[]) {
    this.recognitionRules = Object.freeze(recognition.map(r => new CompiledRule(r)));
    this.beforeRules = Object.freeze(beforeTranslation.map(r => new CompiledRule(r)));
  }

  static forPack(pack: LanguagePack): RuleEngine {
    return new RuleEngine(pack.recognition, pack.beforeTranslation);
  }

  /** Fixes recognizer mishearings. A pack without recognition rules returns `text` untouched. */
  fixRecognition(text: string): string {
    return applyAll(this.recognitionRules, text);
  }

  /**
   * The text given to the translator: recognition fixes, then the before-translation rules, with
   * the gaps they leave tidied. If the rules leave no letter at all (only vocatives were spoken)
   * the recognition-fixed text is kept rather than translating nothing. A pack without
   * before-translation rules returns `fixRecognition`'s result.
   */
  forTranslation(text: string): string {
    const fixed = this.fixRecognition(text);
    if (this.beforeRules.length === 0) {
      return fixed;
    }
    const rewritten = tidy(applyAll(this.beforeRules, fixed), text);
    return /\p{L}/u.test(rewritten) ? rewritten : fixed;
  }
}

function applyAll(rules: readonly CompiledRule[], text: string): string {
  if (rules.length === 0) {
    return text;
  }
  let s = text.normalize('NFC');
  for (const rule of rules) {
    s = rule.apply(s);
  }
  return s;
}

/** Removes the gaps and stray punctuation left by deletions, and capitalizes a sentence start. */
function tidy(text: string, original: string): string {
  let s = text
    .replace(/\s+/gu, ' ')
    .replace(/\s+([,.!?])/gu, '$1')
    .replace(/([,.!?]),+/gu, '$1')
    .replace(/^[\s,.!]+/u, '')
    .replace(/\s+$/u, '');
  if (s !== '' && original !== '') {
    const first = firstGrapheme(s);
    if (isLower(first) && isUpper(firstGrapheme(original))) {
      s = first.toUpperCase() + s.slice(first.length);
    }
  }
  return s;
}

const isLower = (g: string): boolean => g.toUpperCase() !== g && g.toLowerCase() === g;
const isUpper = (g: string): boolean => g.toLowerCase() !== g && g.toUpperCase() === g;

/**
 * The first user-perceived character of a non-empty `s`: its first code point with the marks
 * (and joiner sequences) that follow it. Hermes has no `Intl.Segmenter`; this covers what the
 * Dart `characters` package gives for a sentence start (letters with combining marks).
 */
function firstGrapheme(s: string): string {
  const m = /^.(?:[\p{M}\u{1F3FB}-\u{1F3FF}]|‍.)*/su.exec(s);
  return m ? m[0] : s;
}
