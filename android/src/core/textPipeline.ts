// Port of app/lib/core/text_pipeline.dart. Contract: shared/fixtures/text_pipeline.json
// (shared/fixtures/README.md, "text_pipeline.json — TextPipeline").
import type {LanguagePack, Term} from './model';
import {RuleEngine} from './ruleEngine';
import {Masked, TermProtector} from './termProtector';

/**
 * Which way a phrase is translated: `mine` = the wearer speaks the home language and the other
 * language comes out; `theirs` = the other person speaks and the home language comes out.
 */
export type Direction = 'mine' | 'theirs';

/** A phrase ready for the translator. */
export interface Prepared {
  /** What to translate: rules applied, protected terms replaced by placeholders. */
  readonly text: string;
  /** The same text with the rules applied and the terms in place (the fallback request). */
  readonly unmasked: string;
  /** Language code the translation is into. */
  readonly targetCode: string;
  /** The placeholders and what they stand for. */
  readonly masked: Masked;
}

export interface TextPipelineOptions {
  /** The home language (Vietnamese). */
  readonly home: LanguagePack;
  /** The language picked for the other person. */
  readonly other: LanguagePack;
  /** The user's terms; they win over built-in terms spelled the same. */
  readonly glossary?: readonly Term[];
  /** Placeholder shape per target language code (`{n}` = the number). */
  readonly placeholders?: Readonly<Record<string, string>>;
  readonly defaultPlaceholder?: string;
}

/**
 * Everything done to a phrase around the translator: the source language's rules (recognition
 * fixes, vocatives and idioms rewritten, R9, R13), then protected terms (R10, R11) swapped for
 * placeholders; and the reverse after translation.
 */
export class TextPipeline {
  readonly home: LanguagePack;
  readonly other: LanguagePack;
  readonly glossary: readonly Term[];
  readonly placeholders: Readonly<Record<string, string>>;
  readonly defaultPlaceholder: string;

  private readonly homeRules: RuleEngine;
  private readonly otherRules: RuleEngine;
  private readonly protector = new TermProtector();
  private lost = 0;

  constructor(options: TextPipelineOptions) {
    this.home = options.home;
    this.other = options.other;
    this.glossary = options.glossary ?? [];
    this.placeholders = options.placeholders ?? {};
    this.defaultPlaceholder = options.defaultPlaceholder ?? 'Zorvik{n}';
    this.homeRules = RuleEngine.forPack(this.home);
    this.otherRules = RuleEngine.forPack(this.other);
  }

  /** Placeholders lost by the translator so far (the unmasked fallback ran). */
  get lostPlaceholders(): number {
    return this.lost;
  }

  /** Prepares `text` for translation in `direction`. */
  prepare(text: string, direction: Direction): Prepared {
    const [rules, target] =
      direction === 'mine'
        ? [this.homeRules, this.other.code]
        : [this.otherRules, this.home.code];
    const ruled = rules.forTranslation(text);
    const placeholder = Object.prototype.hasOwnProperty.call(this.placeholders, target)
      ? this.placeholders[target]
      : this.defaultPlaceholder;
    const masked = this.protector.mask(
      ruled,
      [...this.glossary, ...this.home.terms, ...this.other.terms],
      target,
      placeholder,
    );
    return {text: masked.text, unmasked: ruled, targetCode: target, masked};
  }

  /** Puts the protected terms back into `translated`. Null when a placeholder did not survive. */
  finish(translated: string, prepared: Prepared): string | null {
    return this.protector.restore(translated, prepared.masked);
  }

  /**
   * Repairs a translation of the unmasked text: each protected term found as written in the source
   * (whole words, same case) is replaced by its fixed translation.
   */
  repair(translated: string, prepared: Prepared): string {
    let out = translated;
    for (const [surface, output] of prepared.masked.replacements) {
      if (surface === output) {
        continue;
      }
      out = out.replace(TermProtector.wholeWordRegex(surface, true), () => output);
    }
    return out;
  }

  /**
   * Prepare, translate with the injected `translator`, finish. If the translator drops a
   * placeholder, the unmasked text is translated instead and fixed terms are repaired where found
   * (counted in `lostPlaceholders`). A translator error propagates.
   */
  async translate(
    text: string,
    direction: Direction,
    translator: (text: string) => Promise<string>,
  ): Promise<string> {
    if (text.trim() === '') {
      return '';
    }
    const prepared = this.prepare(text, direction);
    const translated = await translator(prepared.text);
    const restored = this.finish(translated, prepared);
    if (restored !== null) {
      return restored;
    }
    this.lost += 1;
    return this.repair(await translator(prepared.unmasked), prepared);
  }
}
