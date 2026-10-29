// Port of app/test/core/translit_test.dart: the TS functions, driven by the tables of
// shared/fixtures/translit.json, are probed over whole Unicode blocks (README, "translit.json").
import {
  asciiDigit,
  hasLetterTable,
  isKana,
  isOmicron,
  latinSpecial,
  punctuation,
  readKana,
  translitLetter,
} from '../src/core/translit';
import {casesOf, loadFixture} from './fixtures';

const fixture = loadFixture('translit');
const cyrillic = fixture.cyrillic as Record<string, string>;
const greek = fixture.greek as Record<string, string>;
const ch = (cp: number) => String.fromCodePoint(cp);
const hex = (cp: number) => `U+${cp.toString(16)}`;
const own = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/** Every BMP code point that is not a surrogate. */
function* bmp(): Generator<number> {
  for (let cp = 0; cp <= 0xffff; cp++) {
    if (cp < 0xd800 || cp > 0xdfff) {
      yield cp;
    }
  }
}

/** Collects mismatches so one failing expectation lists them all. */
function mismatches(cps: Iterable<number>, check: (cp: number) => boolean): string[] {
  const out: string[] = [];
  for (const cp of cps) {
    if (!check(cp)) {
      out.push(hex(cp));
    }
  }
  return out;
}

function* range(lo: number, hi: number): Generator<number> {
  for (let cp = lo; cp <= hi; cp++) {
    yield cp;
  }
}

test('cyrillic: every lower-case letter of U+0400-U+04FF', () => {
  const lowers = [...range(0x400, 0x4ff)].filter(cp => ch(cp).toLowerCase() === ch(cp));
  expect(mismatches(lowers, cp => translitLetter(cp) === (cyrillic[ch(cp)] ?? null))).toEqual([]);
  expect(Object.keys(cyrillic).every(k => k.codePointAt(0)! >= 0x400 && k.codePointAt(0)! <= 0x4ff)).toBe(true);
});

test('greek: every lower-case letter of U+0370-U+03FF and U+1F00-U+1FFF', () => {
  const lowers = [...range(0x370, 0x3ff), ...range(0x1f00, 0x1fff)].filter(
    cp => ch(cp).toLowerCase() === ch(cp),
  );
  expect(mismatches(lowers, cp => translitLetter(cp) === (greek[ch(cp)] ?? null))).toEqual([]);
});

test('no other code point has a letter table', () => {
  expect(
    mismatches(bmp(), cp => {
      const lower = ch(cp).toLowerCase();
      return hasLetterTable(cp) === (own(cyrillic, lower) || own(greek, lower));
    }),
  ).toEqual([]);
});

test('capitals: first letter or, in an all-caps word, all letters', () => {
  for (const c of casesOf(fixture.capitals as never, 'cases')) {
    const cp = (c.letter as string).codePointAt(0)!;
    expect([c.letter, c.allCaps, translitLetter(cp, {allCaps: c.allCaps as boolean})]).toEqual([
      c.letter,
      c.allCaps,
      c.expected,
    ]);
  }
});

test('upsilon after omicron', () => {
  const u = fixture.upsilonAfterOmicron as {letters: string[]; latin: string; omicrons: string[]};
  for (const l of u.letters) {
    expect(translitLetter(l.codePointAt(0)!, {afterOmicron: true})).toBe(u.latin);
  }
  for (const o of u.omicrons) {
    expect(isOmicron(o.codePointAt(0)!)).toBe(true);
  }
  expect(isOmicron('α'.codePointAt(0)!)).toBe(false);
});

test('latinSpecial: every code point of the BMP', () => {
  const table = fixture.latinSpecial as Record<string, string>;
  expect(mismatches(bmp(), cp => latinSpecial(ch(cp)) === (own(table, ch(cp)) ? table[ch(cp)] : null))).toEqual([]);
});

test('punctuation', () => {
  expect(punctuation).toEqual(fixture.punctuation);
});

test('digits of other scripts: every code point of the BMP', () => {
  const zeros = fixture.digitZeros as number[];
  expect(
    mismatches(bmp(), cp => {
      const zero = zeros.find(z => cp >= z && cp <= z + 9);
      return asciiDigit(cp) === (zero === undefined ? null : `${cp - zero}`);
    }),
  ).toEqual([]);
});

describe('kana', () => {
  const kana = fixture.kana as {
    hiragana: Record<string, string>;
    smallY: Record<string, string>;
    hiraganaRange: [number, number];
    katakanaRange: [number, number];
    katakanaOffset: number;
    sokuon: string;
    n: string;
    silent: string[];
    isKana: [number, number][];
  };

  test('each hiragana alone', () => {
    for (const cp of range(kana.hiraganaRange[0], kana.hiraganaRange[1])) {
      const c = ch(cp);
      let want: [string, number] | null;
      if (c === kana.sokuon) {
        want = ['', 1];
      } else if (c === kana.n) {
        want = ['n', 1];
      } else if (own(kana.smallY, c)) {
        want = [`y${kana.smallY[c]}`, 1];
      } else if (own(kana.hiragana, c)) {
        want = [kana.hiragana[c], 1];
      } else {
        want = null;
      }
      expect([hex(cp), readKana([cp], 0)]).toEqual([hex(cp), want]);
    }
  });

  test('katakana reads as the hiragana at the offset', () => {
    for (const cp of range(kana.katakanaRange[0], kana.katakanaRange[1])) {
      expect([hex(cp), readKana([cp], 0)]).toEqual([hex(cp), readKana([cp - kana.katakanaOffset], 0)]);
    }
  });

  test('marks that spell nothing', () => {
    for (const m of kana.silent) {
      expect(readKana([m.codePointAt(0)!], 0)).toEqual(['', 1]);
    }
  });

  test('isKana', () => {
    expect(
      mismatches(range(0x3000, 0x30ff), cp =>
        isKana(cp) === kana.isKana.some(([lo, hi]) => cp >= lo && cp <= hi),
      ),
    ).toEqual([]);
  });

  test('sokuon, n and small ya/yu/yo in context', () => {
    const read = (s: string) => readKana(Array.from(s, c => c.codePointAt(0)!), 0);
    expect(read('っと')).toEqual(['tto', 2]);
    expect(read('っち')).toEqual(['tchi', 2]);
    expect(read('っあ')).toEqual(['a', 2]);
    expect(read('っ')).toEqual(['', 1]);
    expect(read('んあ')).toEqual(["n'", 1]);
    expect(read('んか')).toEqual(['n', 1]);
    expect(read('きょ')).toEqual(['kyo', 2]);
    expect(read('しゃ')).toEqual(['sha', 2]);
    expect(read('ジュ')).toEqual(['ju', 2]);
  });
});
