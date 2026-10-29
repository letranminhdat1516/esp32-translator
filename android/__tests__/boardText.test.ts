// Port of app/test/core/board_text_test.dart (+ what board_glyphs_test can be outside Flutter).
// Cases: shared/fixtures/board_text.json (shared/fixtures/README.md, "board_text.json").
import fs from 'fs';
import path from 'path';

import {BoardGlyphSets, GlyphRangeFormatError, type Range} from '../src/core/boardGlyphs';
import {BoardText} from '../src/core/boardText';
import {FontSets} from '../src/core/model';
import {casesOf, loadFixture, sharedDir, type JsonObject} from './fixtures';

const glyphFile = (name: string) =>
  fs.readFileSync(path.join(sharedDir, 'board_glyphs', `${name}.txt`), 'utf8');

/** The committed lists, as the apps load them. */
const glyphs = BoardGlyphSets.parse({
  cjk: glyphFile('cjk'),
  hangul: glyphFile('hangul'),
  thai: glyphFile('thai'),
});
const text = new BoardText(glyphs);
const fixture = loadFixture('board_text');

const pairs = (json: unknown): Range[] => (json as [number, number][]).map(([lo, hi]) => [lo, hi]);
const sets = (c: JsonObject) => FontSets.fromInt(c.fontSets as number);

/** The BoardText for a case: its own `glyphs` lists, or the shared ones. */
function textOf(c: JsonObject): BoardText {
  const g = c.glyphs as JsonObject | undefined;
  if (g === undefined) {
    return text;
  }
  return new BoardText(
    new BoardGlyphSets({cjk: pairs(g.cjk), hangul: pairs(g.hangul), thai: pairs(g.thai)}),
  );
}

const named = (group: string) => casesOf(fixture, group).map(c => [c.name as string, c] as const);

describe('ranges', () => {
  test.each(named('ranges'))('%s', (_, c) => {
    const r = textOf(c).ranges(sets(c));
    if ('expected' in c) {
      expect(r).toEqual(pairs(c.expected));
    }
    if ('sameAs' in c) {
      expect(r).toEqual(textOf(c).ranges(FontSets.fromInt(c.sameAs as number)));
    }
    if ('expectedLast' in c) {
      expect(r[r.length - 1]).toEqual(pairs([c.expectedLast])[0]);
    }
    if ('noneFrom' in c) {
      expect(r.some(x => x[0] >= (c.noneFrom as number))).toBe(false);
    }
  });
});

describe('isDrawable', () => {
  test.each(named('isDrawable'))('%s', (_, c) => {
    expect(textOf(c).isDrawable(c.codePoint as number, sets(c))).toBe(c.expected);
  });
});

describe('parseRanges', () => {
  test.each(named('parseRanges'))('%s', (_, c) => {
    if (c.error === true) {
      expect(() => BoardGlyphSets.parseRanges(c.input as string)).toThrow(GlyphRangeFormatError);
    } else {
      expect(BoardGlyphSets.parseRanges(c.input as string)).toEqual(pairs(c.expected));
    }
  });
});

describe('encode', () => {
  test.each(named('encode'))('%s', (_, c) => {
    expect(textOf(c).encode(c.input as string, sets(c))).toBe(c.expected);
  });
});

test('every non-blank sample gives output the board can draw', () => {
  const inv = fixture.encodeInvariants as {samples: string[]; fontSets: number[]};
  const problems: string[] = [];
  for (const value of inv.fontSets) {
    const fs_ = FontSets.fromInt(value);
    for (const s of inv.samples) {
      const out = text.encode(s, fs_);
      const bad = Array.from(out).filter(
        c => c !== ' ' && !text.isDrawable(c.codePointAt(0)!, fs_),
      );
      if (out === '' || bad.length > 0 || out !== out.trim() || out.includes('  ')) {
        problems.push(`${JSON.stringify(s)} with ${value} -> ${JSON.stringify(out)}`);
      }
    }
  }
  expect(problems).toEqual([]);
});

describe('BoardGlyphSets.shared', () => {
  afterEach(() => BoardGlyphSets.resetShared());

  test('loads the bundled lists once, equal to shared/board_glyphs', () => {
    const loaded = BoardGlyphSets.load();
    expect(BoardGlyphSets.load()).toBe(loaded);
    expect(BoardGlyphSets.shared).toBe(loaded);
    const all = FontSets.fromInt(28); // cjk + hangul + thai
    expect(loaded.rangesFor(all)).toEqual(glyphs.rangesFor(all));
  });

  test('an injected set wins and is kept', () => {
    const own = new BoardGlyphSets({cjk: [[0x4e00, 0x4e00]]});
    expect(BoardGlyphSets.load(own)).toBe(own);
    expect(BoardGlyphSets.load()).toBe(own);
    expect(new BoardText().isDrawable(0x4e00, FontSets.cjk)).toBe(true);
    expect(new BoardText().isDrawable(0x4e01, FontSets.cjk)).toBe(false);
  });

  test('never loaded: non-Latin text takes the dot fallback, no crash', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      const board = new BoardText();
      const cjkHangulThai = FontSets.fromInt(28); // cjk + hangul + thai
      expect(board.isDrawable(0x4e00, cjkHangulThai)).toBe(false);
      expect(board.encode('東京 Xin chào', cjkHangulThai)).toBe('· Xin chào');
      expect(board.encode('안녕', cjkHangulThai)).toBe('·');
      // and a later load still wins
      BoardGlyphSets.load();
      expect(new BoardText().encode('東京', cjkHangulThai)).toBe('東京');
    } finally {
      warn.mockRestore();
    }
  });

  test('a Latin-only board never needs the lists', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      expect(new BoardText().encode('Привет 東京', FontSets.latinVI)).toBe('Privet ·');
      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });
});
