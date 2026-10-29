/* eslint-disable no-bitwise -- FontSets is a bit mask */
// Port of app/lib/core/board_text.dart. Contract: shared/fixtures/board_text.json
// (shared/fixtures/README.md, "board_text.json — BoardText, transliteration, glyph lists").
import {BoardGlyphSets, type Range} from './boardGlyphs';
import {FontSets} from './model';
import {
  asciiDigit,
  hasLetterTable,
  isKana,
  isOmicron,
  latinSpecial,
  punctuation,
  readKana,
  translitLetter,
} from './translit';

// The canonical ranges (progress.md ruling). latinVI is the firmware's `-r` list; latinExtA adds
// U+0100-U+017F, which contains the four single Vietnamese letter pairs that latinVI lists alone.
const latinVI: readonly Range[] = [
  [0x20, 0x7e],
  [0xa0, 0xff],
  [0x102, 0x103],
  [0x110, 0x111],
  [0x128, 0x129],
  [0x168, 0x169],
  [0x1a0, 0x1a1],
  [0x1af, 0x1b0],
  [0x1ea0, 0x1ef9],
  [0x2013, 0x2014],
  [0x2018, 0x201d],
  [0x2026, 0x2026],
];
const latinExtA: readonly Range[] = [[0x100, 0x17f]];
const dot = '·';
const extraFonts = FontSets.cjk.or(FontSets.hangul).or(FontSets.thai);

// Merged ranges per glyph lists and font bits.
const cache = new WeakMap<object, Map<number, readonly Range[]>>();
const noGlyphs = {};

// eslint-disable-next-line no-control-regex -- control characters separate words
const separator = /[\s\u0000-\u001f\u007f-\u009f\u00a0\u2028\u2029]+/;
const marksAndInvisibles = /^[\p{M}\p{C}]$/u;
const letterOrNumber = /^[\p{L}\p{N}]$/u;
const marks = /\p{M}/gu;
const ownKey = (o: object, k: string): boolean => Object.prototype.hasOwnProperty.call(o, k);

/**
 * Makes text safe for the board: every character left is one the board's fonts can draw, given the
 * glyph sets it reports (`FontSets`).
 *
 * - Characters in the drawable ranges pass through.
 * - Cyrillic and Greek are transliterated to Latin; with no CJK font Japanese kana becomes romaji.
 * - Latin letters the fonts lack are folded to ASCII (`Ł` -> `L`, `ž` -> `z`), fullwidth and other
 *   compatibility forms to their plain equivalents, a few symbols are spelled (`€` -> `EUR`).
 * - Letters of a script with no table and no font (Han, Hangul, Thai, Arabic, ...) give `·`, once
 *   per run. Marks, emoji and other symbols are dropped.
 * - Whitespace and control characters collapse to single spaces.
 * - The result is never empty for non-blank input (`·` when nothing is left). Blank stays blank.
 */
export class BoardText {
  /**
   * `glyphs` are the exact code points of the CJK, Hangul and Thai fonts (subsets, not whole
   * blocks). Absent means `BoardGlyphSets.shared` (see `BoardGlyphSets.load`); it is only read for
   * a board with one of those fonts.
   */
  constructor(readonly glyphs?: BoardGlyphSets) {}

  /**
   * The code point ranges the board can draw with `sets`, sorted, overlapping ranges merged. Latin
   * Basic and the Vietnamese letters are always included: a board that reports no Latin bit is
   * treated as latinVI. The CJK, Hangul and Thai fonts are subsets: only their listed code points.
   */
  ranges(sets: FontSets): readonly Range[] {
    const source =
      (sets.value & extraFonts.value) !== 0 ? this.glyphs ?? BoardGlyphSets.shared : null;
    const key = source ?? noGlyphs;
    let perSets = cache.get(key);
    if (perSets === undefined) {
      perSets = new Map();
      cache.set(key, perSets);
    }
    const hit = perSets.get(sets.value);
    if (hit !== undefined) {
      return hit;
    }
    const all: Range[] = [
      ...latinVI,
      ...(sets.contains(FontSets.latinExtA) ? latinExtA : []),
      ...(source?.rangesFor(sets) ?? []),
    ].sort((a, b) => a[0] - b[0]);
    const merged: Range[] = [];
    for (const r of all) {
      const last = merged[merged.length - 1];
      if (last !== undefined && r[0] <= last[1]) {
        merged[merged.length - 1] = [last[0], Math.max(r[1], last[1])];
      } else {
        merged.push(r);
      }
    }
    const result = Object.freeze(merged);
    perSets.set(sets.value, result);
    return result;
  }

  /** True when the board can draw `codePoint` with `sets`. */
  isDrawable(codePoint: number, sets: FontSets): boolean {
    const r = this.ranges(sets);
    let lo = 0;
    let hi = r.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (codePoint < r[mid][0]) {
        hi = mid - 1;
      } else if (codePoint > r[mid][1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  /** `text` as the board can show it. */
  encode(text: string, sets: FontSets): string {
    const source = text.normalize('NFC');
    const words: string[] = [];
    for (const word of source.split(separator)) {
      if (word === '') {
        continue;
      }
      const encoded = this.word(word, sets);
      if (encoded !== '') {
        words.push(encoded);
      }
    }
    const out = words.join(' ').replace(/ {2,}/g, ' ').trim();
    if (out !== '') {
      return out;
    }
    return source.trim() === '' ? '' : dot;
  }

  private word(word: string, sets: FontSets): string {
    const runes = this.compatibilityFolded(codePoints(word), sets);

    // A word of capitals keeps its transliteration in capitals ("ЖУК" -> "ZHUK", not "ZhUK").
    const letters = runes.filter(hasLetterTable);
    const allCaps =
      letters.length >= 2 &&
      letters.every(r => {
        const c = String.fromCodePoint(r);
        return c.toLowerCase() !== c;
      });

    const parts: string[] = [];
    const emitDot = () => {
      if (parts.length === 0 || parts[parts.length - 1] !== dot) {
        parts.push(dot);
      }
    };

    let i = 0;
    while (i < runes.length) {
      const cp = runes[i];
      const ch = String.fromCodePoint(cp);
      i++;
      if (this.isDrawable(cp, sets)) {
        parts.push(ch);
        continue;
      }
      const letter = translitLetter(cp, {
        allCaps,
        afterOmicron: i >= 2 && isOmicron(runes[i - 2]),
      });
      if (letter !== null) {
        parts.push(letter);
        continue;
      }
      if (isKana(cp)) {
        const kana = readKana(runes, i - 1);
        if (kana === null) {
          emitDot();
        } else {
          parts.push(kana[0]);
          i += kana[1] - 1;
        }
        continue;
      }
      const spelled =
        (ownKey(punctuation, ch) ? punctuation[ch] : null) ??
        latinSpecial(ch) ??
        asciiDigit(cp) ??
        this.foldMarks(ch, sets);
      if (spelled !== null) {
        parts.push(spelled);
        continue;
      }
      if (marksAndInvisibles.test(ch)) {
        continue;
      }
      if (letterOrNumber.test(ch)) {
        emitDot();
      }
      // Anything else (symbols, emoji, other punctuation) is dropped.
    }
    return parts.join('');
  }

  /**
   * Replaces characters the board cannot draw and no table covers by their compatibility form
   * (fullwidth letters, ligatures, circled digits, halfwidth katakana).
   */
  private compatibilityFolded(runes: number[], sets: FontSets): number[] {
    const out: number[] = [];
    for (const cp of runes) {
      const ch = String.fromCodePoint(cp);
      const handled =
        this.isDrawable(cp, sets) ||
        hasLetterTable(cp) ||
        isKana(cp) ||
        ownKey(punctuation, ch) ||
        latinSpecial(ch) !== null ||
        asciiDigit(cp) !== null ||
        this.foldMarks(ch, sets) !== null;
      out.push(...codePoints(handled ? ch : ch.normalize('NFKC')));
    }
    return out;
  }

  /** A Latin letter with its marks removed, when the result can be drawn (`ž` -> `z`); else null. */
  private foldMarks(ch: string, sets: FontSets): string | null {
    const base = ch.normalize('NFD').replace(marks, '');
    if (base === '' || base === ch) {
      return null;
    }
    return codePoints(base).every(r => this.isDrawable(r, sets)) ? base : null;
  }
}

/** Dart `String.runes`: code points, a lone surrogate as itself. */
function codePoints(s: string): number[] {
  return Array.from(s, c => c.codePointAt(0)!);
}
