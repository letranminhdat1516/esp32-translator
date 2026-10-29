// Port of app/test/core/language_catalog_test.dart. Cases: shared/fixtures/language_catalog.json
// (shared/fixtures/README.md, "language_catalog.json — LanguageCatalog").
import {LanguageCatalog, type Platform} from '../src/core/languageCatalog';
import {
  recognizerKinds,
  type Capabilities,
  type LanguagePack,
  type RecognizerKind,
} from '../src/core/model';
import {bundledPacks} from '../src/core/sharedAssets';
import {casesOf, loadFixture, type JsonObject} from './fixtures';

function pack(code: string, label: string): LanguagePack {
  return {
    code,
    appleLocale: `${code}-A`,
    androidLocale: `${code}-B`,
    whisperCode: code,
    label,
    labelLatin: code.toUpperCase(),
    script: 'latin',
    minConfidence: null,
    recognition: [],
    beforeTranslation: [],
    terms: [],
    hints: [],
  };
}

const packsOf = (json: unknown): LanguagePack[] =>
  (json as JsonObject[]).map(p => pack(p.code as string, p.label as string));

function capsOf(json: JsonObject): Capabilities {
  return {
    recognizers: json.recognizers as Record<string, RecognizerKind[]>,
    translatable: new Set(json.translatable as string[]),
    vietnameseVoice: true,
  };
}

const fixture = loadFixture('language_catalog');
const packs = packsOf(fixture.packs);

function catalogOf(c: JsonObject): LanguageCatalog {
  return new LanguageCatalog({
    packs: c.packs === undefined ? packs : packsOf(c.packs),
    caps: capsOf(c.caps as JsonObject),
    platform: c.platform as Platform,
    onlineConsent: new Set((c.consent as string[] | undefined) ?? []),
  });
}

describe('offered', () => {
  test.each(casesOf(fixture, 'offered').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    expect(catalogOf(c).offered.map(p => p.code)).toEqual(c.expected);
  });
});

describe('chain', () => {
  test('RecognizerKind order is the chain order', () => {
    expect(recognizerKinds).toEqual(fixture.chainOrder);
  });

  test.each(casesOf(fixture, 'chain').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    expect(catalogOf(c).chain(c.code as string)).toEqual(c.expected);
  });
});

test('an unknown platform is rejected', () => {
  for (const p of fixture.invalidPlatforms as string[]) {
    expect(
      () =>
        new LanguageCatalog({
          packs,
          caps: capsOf({recognizers: {}, translatable: []}),
          platform: p as Platform,
        }),
    ).toThrow(RangeError);
  }
});

test('the home language is Vietnamese', () => {
  expect(LanguageCatalog.homeCode).toBe(fixture.homeCode);
});

// Not fixture-driven: read-only results.
test('offered and chain are read-only', () => {
  const catalog = new LanguageCatalog({
    packs,
    caps: capsOf({recognizers: {en: ['whisper']}, translatable: ['en']}),
    platform: 'android',
  });
  expect(Object.isFrozen(catalog.offered)).toBe(true);
  expect(Object.isFrozen(catalog.chain('en'))).toBe(true);
  expect(catalog.chain('xx')).toEqual([]);
});

test('Android chain: on-device OS, then Whisper, then online only with consent', () => {
  const caps = capsOf({
    recognizers: {en: ['osOnline', 'whisper', 'osOnDevice']},
    translatable: ['en'],
  });
  const withConsent = new LanguageCatalog({
    packs,
    caps,
    platform: 'android',
    onlineConsent: new Set(['en']),
  });
  expect(withConsent.chain('en')).toEqual(['osOnDevice', 'whisper', 'osOnline']);
  expect(new LanguageCatalog({packs, caps, platform: 'android'}).chain('en')).toEqual([
    'osOnDevice',
    'whisper',
  ]);
});

test('the bundled packs: English is offered when the phone can handle it', () => {
  const catalog = new LanguageCatalog({
    packs: bundledPacks(),
    caps: capsOf({recognizers: {en: ['whisper'], vi: ['whisper']}, translatable: ['en', 'vi']}),
    platform: 'android',
  });
  expect(catalog.offered.map(p => p.code)).toEqual(['en']);
});
