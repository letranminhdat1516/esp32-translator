// Port of app/test/core/text_pipeline_test.dart. Cases: shared/fixtures/text_pipeline.json
// (shared/fixtures/README.md, "text_pipeline.json — TextPipeline").
import {
  languagePackFromJson,
  parseLanguagePack,
  termFromJson,
  type LanguagePack,
  type Term,
} from '../src/core/model';
import {TextPipeline, type Direction} from '../src/core/textPipeline';
import {casesOf, loadFixture, readPackJson, type JsonObject} from './fixtures';

const fixture = loadFixture('text_pipeline');

const packs = new Map<string, LanguagePack>(
  Object.entries(fixture.packs as JsonObject).map(([id, spec]) => {
    const s = spec as JsonObject;
    const file = s.file as string | undefined;
    return [id, file !== undefined ? parseLanguagePack(readPackJson(file)) : languagePackFromJson(s)];
  }),
);

/** A term from its fixture JSON (`id` defaults to `text`, `origin` to user). */
function termOf(j: JsonObject): Term {
  return termFromJson({id: j.text, ...j}, 'term');
}

function pipelineOf(c: JsonObject): TextPipeline {
  return new TextPipeline({
    home: packs.get(c.home as string)!,
    other: packs.get(c.other as string)!,
    glossary: ((c.glossary as JsonObject[] | undefined) ?? []).map(termOf),
    placeholders: (c.placeholders as Record<string, string> | undefined) ?? {},
    defaultPlaceholder: fixture.defaultPlaceholder as string,
  });
}

describe('prepare / finish', () => {
  test.each(casesOf(fixture, 'prepare').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    const p = pipelineOf(c);
    const prep = p.prepare(c.input as string, c.direction as Direction);
    expect(prep.text).toBe(c.prepared);
    for (const f of casesOf(c, 'finish')) {
      expect([f.translated, p.finish(f.translated as string, prep)]).toEqual([
        f.translated,
        f.expected,
      ]);
    }
  });
});

describe('translate', () => {
  test.each(casesOf(fixture, 'translate').map(c => [c.name as string, c] as const))(
    '%s',
    async (_, c) => {
      const p = pipelineOf(c);
      const responses = c.responses as string[];
      const requests: string[] = [];
      const out = await p.translate(c.input as string, c.direction as Direction, async s => {
        requests.push(s);
        return responses[requests.length - 1];
      });
      expect(requests).toEqual(c.requests);
      expect(out).toBe(c.expected);
      expect(p.lostPlaceholders).toBe(c.lostPlaceholders);
    },
  );

  // Not fixture-driven: an exception thrown by the injected translator.
  test('a translator error propagates', async () => {
    const p = new TextPipeline({home: packs.get('vi')!, other: packs.get('en')!});
    await expect(
      p.translate('xin chào', 'mine', async () => {
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');
  });

  test('blank input is not translated', async () => {
    const p = new TextPipeline({home: packs.get('vi')!, other: packs.get('en')!});
    const translator = jest.fn(async (s: string) => s);
    expect(await p.translate('  ', 'mine', translator)).toBe('');
    expect(translator).not.toHaveBeenCalled();
  });

  test('prepare tells the target and keeps the unmasked text', () => {
    const p = new TextPipeline({
      home: packs.get('vi')!,
      other: packs.get('en')!,
      glossary: [termOf({text: 'Zalo'})],
    });
    const prep = p.prepare('gửi qua Zalo', 'mine');
    expect(prep.targetCode).toBe('en');
    expect(prep.unmasked).toBe('gửi qua Zalo');
    expect(prep.text).toBe('gửi qua Zorvik1');
    expect(p.prepare('via Zalo', 'theirs').targetCode).toBe('vi');
  });

  test('repair replaces fixed terms as whole words, literally', () => {
    const p = new TextPipeline({
      home: packs.get('vi')!,
      other: packs.get('en')!,
      glossary: [termOf({text: 'Phở', fixed: {en: '$1 soup'}})],
    });
    const prep = p.prepare('ăn Phở', 'mine');
    expect(p.repair('eat Phở, Phởs', prep)).toBe('eat $1 soup, Phởs');
  });
});
