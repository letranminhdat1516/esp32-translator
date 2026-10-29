// Port of app/test/core/model_test.dart. Cases: shared/fixtures/model.json.
import {
  BoardInfo,
  Capabilities,
  FontSets,
  LanguagePack,
  PackError,
  boardInfoEquals,
  capabilitiesEquals,
  parseLanguagePack,
  recognizerKinds,
  scripts,
  Script,
} from '../src/core/model';
import {
  JsonObject,
  casesOf,
  loadFixture,
  readPackJson,
  shippedPackCodes,
} from './fixtures';

const fixture = loadFixture('model');

/** A pack JSON built from `shared/languages/<base>.json` with fields set or removed. */
function packJson(c: JsonObject): string {
  const m = JSON.parse(readPackJson(c.base as string)) as JsonObject;
  for (const k of (c.remove as string[] | undefined) ?? []) {
    delete m[k];
  }
  Object.assign(m, (c.set as JsonObject | undefined) ?? {});
  return JSON.stringify(m);
}

function parseError(json: string): PackError {
  try {
    parseLanguagePack(json);
  } catch (e) {
    if (e instanceof PackError) {
      return e;
    }
    throw e;
  }
  throw new Error('no PackError');
}

/** JSON round trip (Dart toJson): the parsed pack serializes back to an equal pack. */
function expectRoundTrip(p: LanguagePack): void {
  expect(parseLanguagePack(JSON.stringify(p))).toEqual(p);
}

test('enum names', () => {
  expect(scripts).toEqual(fixture.scripts);
  expect(recognizerKinds).toEqual(fixture.recognizerKinds);
});

describe('shipped packs parse', () => {
  const shipped = fixture.shippedPacks as JsonObject;

  test('every shared/languages/*.json parses', () => {
    const codes = shippedPackCodes();
    expect(codes.length).toBeGreaterThan(0);
    for (const code of codes) {
      expect(parseLanguagePack(readPackJson(code)).code).toBe(code);
    }
  });

  for (const [code, value] of Object.entries(shipped)) {
    test(`${code}.json`, () => {
      const want = value as JsonObject;
      const p = parseLanguagePack(readPackJson(code));
      expect(p.code).toBe(want.code);
      expect(p.appleLocale).toBe(want.appleLocale);
      expect(p.androidLocale).toBe(want.androidLocale);
      expect(p.whisperCode).toBe(want.whisperCode);
      expect(p.label).toBe(want.label);
      expect(p.labelLatin).toBe(want.labelLatin);
      expect(p.script).toBe(want.script);
      expect(p.minConfidence).toBe(want.minConfidence);
      expect(p.recognition.length > 0).toBe(want.hasRecognition);
      expect(p.beforeTranslation.length > 0).toBe(want.hasBeforeTranslation);
      expect(p.terms.length).toBe(want.termCount);
      expect(p.hints.length).toBe(want.hintCount);
      expectRoundTrip(p);
    });
  }
});

describe('packOk', () => {
  for (const c of casesOf(fixture, 'packOk')) {
    test(c.name as string, () => {
      const p = parseLanguagePack(packJson(c));
      const want = c.expect as JsonObject;
      if ('script' in want) {
        expect(p.script).toBe(want.script);
      }
      if ('recognitionCount' in want) {
        expect(p.recognition.length).toBe(want.recognitionCount);
      }
      if ('atClauseStart' in want) {
        expect(p.recognition[0].atClauseStart).toBe(want.atClauseStart);
      }
      if ('termOrigin' in want) {
        expect(p.terms).toHaveLength(1);
        expect(p.terms[0].origin).toBe(want.termOrigin);
      }
      if ('hints' in want) {
        expect(p.hints).toEqual(want.hints);
      }
      if ('minConfidence' in want) {
        expect(p.minConfidence).toBe(want.minConfidence);
      }
      expectRoundTrip(p);
    });
  }
});

describe('packErrors', () => {
  for (const c of casesOf(fixture, 'packErrors')) {
    test(`${c.name} throws PackError(${c.field})`, () => {
      expect(parseError(packJson(c)).field).toBe(c.field);
    });
  }
});

// Not in the fixture (it has only the field paths): the reason texts, captured by running
// app/lib/core/model.dart on the same inputs. Regex messages come from the JS engine; under
// Node (V8) they equal Dart's, other engines only keep the "invalid regex: " prefix.
describe('PackError reasons equal the Dart ones', () => {
  const fixtureReasons: Record<string, string> = {
    'missing label': 'missing',
    'label of the wrong type': 'must be a string',
    'invalid recognition pattern': 'invalid regex: Unterminated group',
    'invalid beforeTranslation context':
      'invalid regex: Unterminated character class',
    'unknown script': 'unknown script "klingon"',
    'rule missing its template': 'missing',
    'term with an unknown origin': 'unknown origin "robot"',
    'term fixed value not a string': 'values must be strings',
    'hints entry not a string': 'entries must be strings',
    'recognition entry not an object': 'must be an object',
  };
  for (const c of casesOf(fixture, 'packErrors')) {
    test(c.name as string, () => {
      expect(parseError(packJson(c)).reason).toBe(fixtureReasons[c.name as string]);
    });
  }

  const base = (): JsonObject => JSON.parse(readPackJson('en')) as JsonObject;
  const more: Array<[string, JsonObject, string, string]> = [
    ['minConfidence string', {minConfidence: 'x'}, 'minConfidence', 'must be a num'],
    ['minConfidence bool', {minConfidence: true}, 'minConfidence', 'must be a num'],
    [
      'rule atClauseStart int',
      {recognition: [{id: 'r', pattern: 'a', template: 'b', atClauseStart: 1}]},
      'recognition[0].atClauseStart',
      'must be a bool',
    ],
    [
      'rule context int',
      {recognition: [{id: 'r', pattern: 'a', template: 'b', context: 1}]},
      'recognition[0].context',
      'must be a String',
    ],
    ['recognition not a list', {recognition: 'x'}, 'recognition', 'must be a List<dynamic>'],
    ['hints not a list', {hints: 'x'}, 'hints', 'must be a List<dynamic>'],
    [
      'term fixed not a map',
      {terms: [{id: 't', text: 'x', fixed: [1]}]},
      'terms[0].fixed',
      'must be a Map<dynamic, dynamic>',
    ],
    [
      'term variant not a string',
      {terms: [{id: 't', text: 'x', variants: [1]}]},
      'terms[0].variants',
      'entries must be strings',
    ],
    [
      'term origin not a string',
      {terms: [{id: 't', text: 'x', origin: 1}]},
      'terms[0].origin',
      'must be a String',
    ],
    ['term without id', {terms: [{text: 'x'}]}, 'terms[0].id', 'missing'],
    ['code not a string', {code: 1}, 'code', 'must be a string'],
    ['script not a string', {script: 1}, 'script', 'must be a string'],
    ['code null', {code: null}, 'code', 'missing'],
  ];
  for (const [name, set, field, reason] of more) {
    test(name, () => {
      const e = parseError(JSON.stringify({...base(), ...set}));
      expect([e.field, e.reason]).toEqual([field, reason]);
    });
  }

  test('invalid JSON and a non-object', () => {
    const bad = parseError('{"x":');
    expect(bad.field).toBe('');
    expect(bad.reason.startsWith('invalid JSON: ')).toBe(true);
    const arr = parseError('[1]');
    expect([arr.field, arr.reason]).toEqual(['', 'pack must be a JSON object']);
    // Dart reads `script` first, so an empty object fails there.
    const empty = parseError('{"code":null}');
    expect([empty.field, empty.reason]).toEqual(['script', 'missing']);
  });

  test('toString like Dart', () => {
    expect(String(new PackError('label', 'missing'))).toBe('PackError(label): missing');
  });
});

describe('FontSets', () => {
  test('bit values', () => {
    const bits = fixture.fontSetBits as JsonObject;
    expect(FontSets.latinVI.value).toBe(bits.latinVI);
    expect(FontSets.latinExtA.value).toBe(bits.latinExtA);
    expect(FontSets.cjk.value).toBe(bits.cjk);
    expect(FontSets.hangul.value).toBe(bits.hangul);
    expect(FontSets.thai.value).toBe(bits.thai);
  });

  for (const c of casesOf(fixture, 'covers')) {
    test(c.name as string, () => {
      expect(FontSets.fromInt(c.fontSets as number).covers(c.script as Script)).toBe(
        c.expected,
      );
    });
  }

  test('or, contains and equality', () => {
    const s = FontSets.latinVI.or(FontSets.thai);
    expect(s.value).toBe(17);
    expect(s.contains(FontSets.thai)).toBe(true);
    expect(s.contains(FontSets.cjk)).toBe(false);
    expect(s.equals(FontSets.fromInt(17))).toBe(true);
    expect(s.equals(FontSets.fromInt(16))).toBe(false);
  });

  test('the full u32 stays unsigned', () => {
    const all = FontSets.fromInt(0xffffffff);
    expect(all.value).toBe(4294967295);
    expect(all.contains(FontSets.thai)).toBe(true);
    expect(all.or(FontSets.cjk).value).toBe(4294967295);
  });
});

describe('Capabilities and BoardInfo', () => {
  test('value equality', () => {
    const mk = (): Capabilities => ({
      recognizers: {en: ['osOnDevice', 'whisper']},
      translatable: new Set(['en', 'ja']),
      vietnameseVoice: true,
    });
    expect(capabilitiesEquals(mk(), mk())).toBe(true);
    expect(
      capabilitiesEquals(mk(), {...mk(), recognizers: {en: ['osOnline']}}),
    ).toBe(false);
    expect(capabilitiesEquals(mk(), {...mk(), translatable: new Set(['en'])})).toBe(
      false,
    );
    expect(capabilitiesEquals(mk(), {...mk(), vietnameseVoice: false})).toBe(false);
    expect(
      capabilitiesEquals(mk(), {...mk(), recognizers: {en: ['osOnDevice', 'whisper'], ja: []}}),
    ).toBe(false);

    const info = (v: number): BoardInfo => ({protocolVersion: v, fontSets: FontSets.latinVI});
    expect(boardInfoEquals(info(1), info(1))).toBe(true);
    expect(boardInfoEquals(info(1), info(2))).toBe(false);
    expect(
      boardInfoEquals(info(1), {protocolVersion: 1, fontSets: FontSets.fromInt(1)}),
    ).toBe(true);
  });
});
