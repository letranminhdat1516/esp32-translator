// Term harness (P2.5, R10): the pure part driven by scripts/term-harness.mjs. Cases:
// shared/fixtures/terms/harness.json, the same ones ios/Tools/term-harness passes; plus the corpus
// itself (shared/fixtures/terms/<lang>.tsv) checked for shape and size.
import fs from 'fs';
import path from 'path';
import {
  CorpusError,
  SHAPES,
  TermNotFoundError,
  bestShapes,
  evaluate,
  parseCorpus,
  escapeField,
  report,
  runCorpus,
  scripted,
  unescapeField,
  setPlaceholder,
  type Result,
} from '../src/harness/termHarness';
import {TermProtector} from '../src/core/termProtector';
import {casesOf, loadFixture, sharedDir, type JsonObject} from './fixtures';

const fixture = loadFixture('terms/harness');

test('the shapes are the fixture list', () => {
  expect([...SHAPES]).toEqual(fixture.shapes);
});

describe('parse', () => {
  test.each(casesOf(fixture, 'parse').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    const run = () => parseCorpus(c.text as string, c.lang as string);
    if (c.error !== undefined) {
      const e = c.error as JsonObject;
      let thrown: unknown;
      try {
        run();
      } catch (err) {
        thrown = err;
      }
      expect(thrown).toBeInstanceOf(CorpusError);
      expect([(thrown as CorpusError).kind, (thrown as CorpusError).lineNo]).toEqual([e.kind, e.lineNo]);
      return;
    }
    expect(run().map(l => ({...l}))).toEqual(
      (c.expected as JsonObject[]).map(e => ({...e, lang: c.lang})),
    );
  });
});

describe('evaluate', () => {
  test.each(casesOf(fixture, 'evaluate').map(c => [c.name as string, c] as const))(
    '%s',
    async (_, c) => {
      const [line] = parseCorpus(c.line as string, c.lang as string);
      const translations = c.translations as Record<string, string>;
      const asked: string[] = [];
      const translate = async (text: string) => {
        asked.push(text);
        if (!(text in translations)) {
          throw new Error(`unexpected request ${JSON.stringify(text)}`);
        }
        return translations[text];
      };
      const run = evaluate(line, c.shape as string, translate);
      if (c.error !== undefined) {
        expect(c.error).toBe('termNotFound');
        await expect(run).rejects.toBeInstanceOf(TermNotFoundError);
        return;
      }
      const o = await run;
      const e = c.expected as JsonObject;
      expect(o.masked).toBe(c.masked);
      expect({asked, restored: o.restored, output: o.output, passed: o.passed}).toEqual(e);
    },
  );
});

test.each(casesOf(fixture, 'scripted').map(c => [c.input as string, c.output as string]))(
  'scripted fake: %s',
  (input, output) => {
    expect(scripted(input)).toBe(output);
  },
);

describe('report', () => {
  test.each(casesOf(fixture, 'report').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    const results = c.results as unknown as Result[];
    const shapes = c.shapes as string[];
    expect(Object.fromEntries(bestShapes(results, shapes))).toEqual(c.best);
    expect(report(results, shapes, c.engine as string)).toBe(c.markdown);
  });
});

describe('setPlaceholder', () => {
  test.each(casesOf(fixture, 'setPlaceholder').map(c => [c.name as string, c] as const))(
    '%s',
    (_, c) => {
      const run = () => setPlaceholder(c.text as string, c.key as string, c.shape as string);
      if (c.error !== undefined) {
        expect(run).toThrow(/whisperCode/);
        return;
      }
      expect(run()).toBe(c.expected);
    },
  );
});

test('TSV fields round-trip through escaping', () => {
  const s = 'a\tb\nc\r\\d \\t';
  expect(escapeField(s)).toBe('a\\tb\\nc\\r\\\\d \\\\t');
  expect(escapeField(s)).not.toMatch(/[\t\n\r]/);
  expect(unescapeField(escapeField(s))).toBe(s);
});

test('runCorpus: every line with every shape; translator errors fail the line', async () => {
  const lines = parseCorpus(
    'en>vi\tI booked a Grab to the airport.\tGrab\tGrab\nvi>en\tTàu từ Hà Nội vào Huế.\tHà Nội\tHanoi',
    'en',
  );
  const asked: string[] = [];
  const {results, errors} = await runCorpus(lines, ['Zorvik{n}', '[[{n}]]'], async (text, from, to) => {
    asked.push(`${from}>${to} ${text}`);
    if (text.includes('[[')) {
      throw new Error('boom');
    }
    return scripted(text);
  });
  expect(results).toEqual([
    {lang: 'en', from: 'en', to: 'vi', shape: 'Zorvik{n}', restored: true, passed: true},
    {lang: 'en', from: 'en', to: 'vi', shape: '[[{n}]]', restored: false, passed: false},
    {lang: 'en', from: 'vi', to: 'en', shape: 'Zorvik{n}', restored: true, passed: true},
    {lang: 'en', from: 'vi', to: 'en', shape: '[[{n}]]', restored: false, passed: false},
  ]);
  expect(errors).toEqual(['en:1 [[{n}]]: boom', 'en:2 [[{n}]]: boom']);
  expect(asked[2]).toBe('vi>en Tàu từ Zorvik1 vào Huế.');
});

describe('corpus', () => {
  const dir = path.join(sharedDir, 'fixtures', 'terms');
  const files = fs.readdirSync(dir).filter(f => f.endsWith('.tsv'));
  test('has every language of the plan', () => {
    expect(files.map(f => f.slice(0, -4)).sort()).toEqual(
      ['de', 'en', 'es', 'fr', 'ja', 'ko', 'th', 'zh-Hans'],
    );
  });
  const protector = new TermProtector();
  test.each(files)('%s: >= 40 lines per direction, every term masked by every shape', file => {
    const lang = file.slice(0, -4);
    const lines = parseCorpus(fs.readFileSync(path.join(dir, file), 'utf8'), lang);
    expect(lines.filter(l => l.to === 'vi').length).toBeGreaterThanOrEqual(40);
    expect(lines.filter(l => l.from === 'vi').length).toBeGreaterThanOrEqual(40);
    const unmasked = lines.flatMap(l =>
      SHAPES.filter(
        shape => protector.mask(l.source, [{id: l.term, text: l.term, variants: [], fixed: {}, origin: 'user'}], l.to, shape).isEmpty,
      ).map(shape => `${l.lineNo} ${shape}`),
    );
    expect(unmasked).toEqual([]);
  });
});
