// Port of app/lib/core/term_protector.dart. Contract: shared/fixtures/terms.json
// (shared/fixtures/README.md, "terms.json — TermProtector"; Review Focus 3).
import {graphemes} from '../board/protocol';
import type {Term} from './model';

/** `mask` was given a placeholder shape without exactly one `{n}` or with nothing around it. */
export class InvalidPlaceholderError extends Error {
  constructor(readonly placeholder: string, reason: string) {
    super(`Invalid placeholder "${placeholder}": ${reason}`);
    this.name = 'InvalidPlaceholderError';
  }
}

/** Text with its protected terms swapped for placeholders, and what each placeholder stands for. */
export class Masked {
  /** @internal Made by `TermProtector.mask`. */
  constructor(
    /** The text to translate. */
    readonly text: string,
    /** Placeholder number -> text it turns back into. */
    readonly outputs: ReadonlyMap<number, string>,
    /** Placeholder number -> the form found in the source text. */
    readonly surfaces: ReadonlyMap<number, string>,
    /** Placeholder number -> how many times it occurs in `text`. */
    readonly counts: ReadonlyMap<number, number>,
    /** Numbers the source text itself already used; they are not ours. */
    readonly taken: ReadonlySet<number>,
    readonly prefix: string,
    readonly suffix: string,
  ) {}

  /** No term was found: `text` is the (NFC) input and nothing needs restoring. */
  get isEmpty(): boolean {
    return this.outputs.size === 0;
  }

  /** [source form, replacement] of every placeholder; used to repair a translation that lost them. */
  get replacements(): [string, string][] {
    return [...this.outputs].map(([n, output]) => [this.surfaces.get(n)!, output]);
  }
}

interface Span {
  readonly start: number;
  readonly end: number;
  readonly term: Term;
  readonly matched: string;
}

const nonLatinLetter = /(?!\p{Script=Latin})\p{L}/u;
const wordChar = /[\p{L}\p{N}]/u;
/** Scripts written without spaces (Thai, Hangul, kana, CJK): no word bound at such an edge. */
const unspaced =
  /[฀-๿ᄀ-ᇿ぀-ヿ㄰-㆏㐀-䶿一-鿿가-힣豈-﫿]/u;

/**
 * Keeps names, brands, places and glossary terms intact through translation (R10): each term found
 * in the source is replaced by a placeholder such as `Zorvik1`, the text is translated, and the
 * placeholders are swapped for the term itself or its fixed translation for the target language.
 *
 * Terms (and their variants) are matched literally, longest first, and text already taken by a
 * longer term is never masked again. Latin text matches case-insensitively (the spoken form is kept
 * when restored), other scripts exactly. Terms whose edges are letters or digits match whole words
 * only, except in scripts written without spaces (CJK, kana, Hangul, Thai).
 */
export class TermProtector {
  /**
   * Replaces the terms found in `text` with placeholders. `placeholder` holds `{n}` once, replaced
   * by 1, 2, ... in order of appearance (numbers already used by the text itself are skipped).
   * `target` picks each term's fixed translation. Throws `InvalidPlaceholderError`.
   */
  mask(text: string, terms: readonly Term[], target: string, placeholder = 'Zorvik{n}'): Masked {
    const slots = placeholder.split('{n}').length - 1;
    if (slots !== 1) {
      throw new InvalidPlaceholderError(placeholder, 'must contain {n} exactly once');
    }
    const at = placeholder.indexOf('{n}');
    const prefix = placeholder.slice(0, at);
    const suffix = placeholder.slice(at + 3);
    if (prefix === '' && suffix === '') {
      throw new InvalidPlaceholderError(placeholder, 'must have text around {n}');
    }

    const s = text.normalize('NFC');
    const candidates: [string, Term][] = [];
    const seen = new Set<string>();
    for (const term of terms) {
      for (const surface of [term.text, ...term.variants]) {
        const c = surface.normalize('NFC');
        if (c !== '' && !seen.has(c)) {
          seen.add(c);
          candidates.push([c, term]);
        }
      }
    }
    // Longest first (UTF-16 length); the sort is stable, so ties keep their input order.
    candidates.sort((a, b) => b[0].length - a[0].length);

    const lower = s.toLowerCase();
    const spans: Span[] = [];
    for (const [candidate, term] of candidates) {
      if (!lower.includes(candidate.toLowerCase())) {
        continue;
      }
      for (const m of s.matchAll(TermProtector.wholeWordRegex(candidate))) {
        const start = m.index!;
        const end = start + m[0].length;
        if (spans.some(o => start < o.end && o.start < end)) {
          continue;
        }
        spans.push({start, end, term, matched: m[0]});
      }
    }
    if (spans.length === 0) {
      return new Masked(s, new Map(), new Map(), new Map(), new Set(), prefix, suffix);
    }
    spans.sort((a, b) => a.start - b.start);

    // Numbers the text already uses ("Zorvik1" typed by the speaker) are skipped, so they cannot
    // be mistaken for a placeholder.
    const taken = new Set([...s.matchAll(slotRegex(prefix, suffix))].map(m => Number(m[1])));
    let next = 0;
    const allocate = (): number => {
      do {
        next += 1;
      } while (taken.has(next));
      return next;
    };

    // One placeholder per fixed translation (all spoken forms of a term share it) or per distinct
    // spoken form.
    const numberByKey = new Map<string, number>();
    const outputs = new Map<number, string>();
    const surfaces = new Map<number, string>();
    const counts = new Map<number, number>();
    let out = '';
    let pos = 0;
    for (const span of spans) {
      const fixed = Object.prototype.hasOwnProperty.call(span.term.fixed, target)
        ? span.term.fixed[target]
        : undefined;
      const key = fixed !== undefined ? `fixed:${span.term.id}` : `text:${span.matched}`;
      let n = numberByKey.get(key);
      if (n === undefined) {
        n = allocate();
        numberByKey.set(key, n);
        outputs.set(n, fixed ?? span.matched);
        surfaces.set(n, span.matched);
      }
      counts.set(n, (counts.get(n) ?? 0) + 1);
      out += s.slice(pos, span.start) + prefix + n + suffix;
      pos = span.end;
    }
    out += s.slice(pos);
    return new Masked(out, outputs, surfaces, counts, taken, prefix, suffix);
  }

  /**
   * Puts the terms back into `translated`. Returns null when a placeholder did not survive
   * translation (lost, duplicated or invented); the caller then translates the unmasked text and
   * repairs fixed terms where found.
   */
  restore(translated: string, m: Masked): string | null {
    if (m.isEmpty) {
      return translated;
    }
    const found = new Map<number, number>();
    let invented = false;
    const restored = translated.replace(slotRegex(m.prefix, m.suffix), (match, digits: string) => {
      const n = Number(digits);
      const output = m.outputs.get(n);
      if (output === undefined) {
        if (!m.taken.has(n)) {
          invented = true;
        }
        return match;
      }
      found.set(n, (found.get(n) ?? 0) + 1);
      return output;
    });
    if (invented) {
      return null;
    }
    for (const [n, count] of m.counts) {
      if (found.get(n) !== count) {
        return null;
      }
    }
    return restored;
  }

  /**
   * Matches `candidate` literally (global), as a whole word where its edges are letters or digits.
   * Case-insensitive for Latin unless `caseSensitive`.
   */
  static wholeWordRegex(candidate: string, caseSensitive?: boolean): RegExp {
    const chars = graphemes(candidate);
    const first = chars[0] ?? '';
    const last = chars[chars.length - 1] ?? '';
    const before = wordChar.test(first) && !unspaced.test(first) ? '(?<![\\p{L}\\p{N}])' : '';
    const after = wordChar.test(last) && !unspaced.test(last) ? '(?![\\p{L}\\p{N}])' : '';
    const exact = caseSensitive ?? nonLatinLetter.test(candidate);
    return new RegExp(`${before}${escapeRegExp(candidate)}${after}`, exact ? 'gu' : 'giu');
  }
}

/** `<prefix>(digits)<suffix>`, case-insensitive, global. */
function slotRegex(prefix: string, suffix: string): RegExp {
  return new RegExp(`${escapeRegExp(prefix)}(\\d+)${escapeRegExp(suffix)}`, 'gi');
}

/** Escapes the regex syntax characters (valid with and without the `u` flag). */
export function escapeRegExp(s: string): string {
  return s.replace(/[\\^$.*+?()[\]{}|/]/g, '\\$&');
}
