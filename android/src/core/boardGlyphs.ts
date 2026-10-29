// Port of app/lib/core/board_glyphs.dart. Contract: shared/fixtures/board_text.json (parseRanges,
// ranges, isDrawable with the lists of shared/board_glyphs/*.txt).
import {FontSets} from './model';
import {boardGlyphTexts, type BoardGlyphTexts} from './sharedAssets';

/** An inclusive code point range `[lo, hi]`. */
export type Range = readonly [number, number];

/** A glyph list line that is not hex, or a reversed range. */
export class GlyphRangeFormatError extends Error {
  constructor(readonly line: string) {
    super(`bad glyph range: ${line}`);
    this.name = 'GlyphRangeFormatError';
  }
}

const sorted = (r: readonly Range[]): readonly Range[] =>
  Object.freeze([...r].sort((a, b) => a[0] - b[0]));

let shared: BoardGlyphSets | null = null;
let warned = false;
/** What `shared` gives before `load` (created on first use: the class is not defined yet). */
let empty: BoardGlyphSets | null = null;

/**
 * The exact code points of the board's partition fonts (CJK, Hangul, Thai). Those fonts are
 * subsets, so whole Unicode blocks are not drawable. The lists are generated from the font files
 * by `firmware/tools/gen_glyph_sets.py` into `shared/board_glyphs/<set>.txt` (bundled through
 * sharedAssets.ts), one `XXXX-YYYY` or `XXXX` per line.
 */
export class BoardGlyphSets {
  private readonly cjk: readonly Range[];
  private readonly hangul: readonly Range[];
  private readonly thai: readonly Range[];

  constructor({
    cjk = [],
    hangul = [],
    thai = [],
  }: {cjk?: readonly Range[]; hangul?: readonly Range[]; thai?: readonly Range[]} = {}) {
    this.cjk = sorted(cjk);
    this.hangul = sorted(hangul);
    this.thai = sorted(thai);
  }

  /** Reads the text of the three list files (see `parseRanges`). */
  static parse(texts: BoardGlyphTexts): BoardGlyphSets {
    return new BoardGlyphSets({
      cjk: BoardGlyphSets.parseRanges(texts.cjk),
      hangul: BoardGlyphSets.parseRanges(texts.hangul),
      thai: BoardGlyphSets.parseRanges(texts.thai),
    });
  }

  /**
   * The lists the app uses unless a `BoardText` is given others. When `load` has not run this
   * warns once (dev builds) and returns one frozen empty set, which is not remembered as the
   * loaded lists, so a later `load` still wins; non-Latin characters then take the `·` fallback. Never throws.
   */
  static get shared(): BoardGlyphSets {
    if (shared !== null) {
      return shared;
    }
    if (__DEV__ && !warned) {
      warned = true;
      console.warn('BoardGlyphSets.load() was not called: CJK/Hangul/Thai text shows as ·');
    }
    if (empty === null) {
      empty = new BoardGlyphSets();
      Object.freeze(empty);
    }
    return empty;
  }

  /**
   * Loads the bundled lists once (or keeps `sets`, for tests); later calls return the same
   * object. Call it at startup, before the first encode for a board with an extra font.
   */
  static load(sets?: BoardGlyphSets): BoardGlyphSets {
    shared ??= sets ?? BoardGlyphSets.parse(boardGlyphTexts);
    return shared;
  }

  /** Forgets the loaded lists (tests). */
  static resetShared(): void {
    shared = null;
    warned = false;
  }

  /** The ranges of the fonts `sets` selects (cjk, hangul and thai bits only). */
  rangesFor(sets: FontSets): Range[] {
    return [
      ...(sets.contains(FontSets.cjk) ? this.cjk : []),
      ...(sets.contains(FontSets.hangul) ? this.hangul : []),
      ...(sets.contains(FontSets.thai) ? this.thai : []),
    ];
  }

  /**
   * Parses `XXXX-YYYY` / `XXXX` lines (hex, no prefix). Blank lines and `#` comments are skipped;
   * anything else throws `GlyphRangeFormatError`.
   */
  static parseRanges(text: string): Range[] {
    const out: Range[] = [];
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (line === '' || line.startsWith('#')) {
        continue;
      }
      const parts = line.split('-');
      const lo = parseHex(parts[0]);
      const hi = parts.length === 1 ? lo : parts.length === 2 ? parseHex(parts[1]) : null;
      if (lo === null || hi === null || hi < lo) {
        throw new GlyphRangeFormatError(line);
      }
      out.push([lo, hi]);
    }
    return out;
  }
}

/** Dart `int.tryParse(s, radix: 16)`: an optional sign and hex digits only, else null. */
function parseHex(s: string): number | null {
  const m = /^([+-]?)([0-9a-fA-F]+)$/.exec(s);
  if (m === null) {
    return null;
  }
  const v = parseInt(m[2], 16);
  return m[1] === '-' ? -v : v;
}
