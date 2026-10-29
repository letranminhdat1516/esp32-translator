// Port of app/test/core/term_protector_test.dart. Cases: shared/fixtures/terms.json
// (shared/fixtures/README.md, "terms.json — TermProtector"; Review Focus 3).
import {termFromJson, type Term} from '../src/core/model';
import {InvalidPlaceholderError, TermProtector} from '../src/core/termProtector';
import {casesOf, loadFixture, type JsonObject} from './fixtures';

/** A term from its fixture JSON (`id` defaults to `text`, `origin` to user). */
function termOf(j: JsonObject): Term {
  return termFromJson({id: j.text, ...j}, 'term');
}

const protector = new TermProtector();
const fixture = loadFixture('terms');
const defaultPlaceholder = fixture.defaultPlaceholder as string;

describe('terms.json cases', () => {
  test.each(casesOf(fixture, 'cases').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    const terms = (c.terms as JsonObject[]).map(termOf);
    const run = () =>
      protector.mask(
        c.text as string,
        terms,
        c.target as string,
        (c.placeholder as string | undefined) ?? defaultPlaceholder,
      );
    if (c.error !== undefined) {
      expect(c.error).toBe('invalidPlaceholder');
      expect(run).toThrow(InvalidPlaceholderError);
      return;
    }
    const m = run();
    expect(m.text).toBe(c.masked);
    if (c.isEmpty !== undefined) {
      expect(m.isEmpty).toBe(c.isEmpty);
    }
    for (const r of casesOf(c, 'restores')) {
      expect([r.translated, protector.restore(r.translated as string, m)]).toEqual([
        r.translated,
        r.expected,
      ]);
    }
  });
});

describe('details not in the fixture', () => {
  test('the default placeholder is Zorvik{n}', () => {
    expect(protector.mask('Zalo', [termOf({text: 'Zalo'})], 'en').text).toBe('Zorvik1');
  });

  test('an invalid placeholder is an argument error naming the shape', () => {
    expect(() => protector.mask('x', [], 'en', 'Zorvik')).toThrow(/Zorvik/);
  });

  test('replacements pair each spoken form with what it turns back into', () => {
    const m = protector.mask('Hà Nội và hanoi', [
      termOf({text: 'Hà Nội', variants: ['Hanoi'], fixed: {en: 'Hanoi'}}),
      termOf({text: 'Zalo'}),
    ], 'en');
    expect(m.replacements).toEqual([['Hà Nội', 'Hanoi']]);
  });

  test('a fixed translation with $ is restored literally', () => {
    const m = protector.mask('giá Zalo', [termOf({text: 'Zalo', fixed: {en: '$1 $& $$'}})], 'en');
    expect(protector.restore('price Zorvik1', m)).toBe('price $1 $& $$');
  });

  test('a term with regex characters and a bound only at its letter edge', () => {
    const re = TermProtector.wholeWordRegex('C++');
    expect('xC++'.match(re)).toBeNull();
    expect('C++x'.match(re)?.[0]).toBe('C++');
  });

  test('a mark at the edge counts with its letter (bound kept)', () => {
    // "é" written as e + U+0301 at the end: the last character is a letter.
    const re = TermProtector.wholeWordRegex('café');
    expect('cafés'.match(re)).toBeNull();
    expect('café s'.match(re)?.[0]).toBe('café');
  });
});
