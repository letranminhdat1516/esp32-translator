// Port of app/test/core/rule_engine_test.dart. Cases: shared/fixtures/rules.json
// (shared/fixtures/README.md, "rules.json — RuleEngine").
import {ruleFromJson, type Rule} from '../src/core/model';
import {RuleEngine} from '../src/core/ruleEngine';
import {bundledPack} from '../src/core/sharedAssets';
import {casesOf, loadFixture, readPackJson, shippedPackCodes, type JsonObject} from './fixtures';
import {parseLanguagePack} from '../src/core/model';

const fixture = loadFixture('rules');

function engineOf(spec: JsonObject): RuleEngine {
  const pack = spec.pack as string | undefined;
  if (pack !== undefined) {
    return RuleEngine.forPack(parseLanguagePack(readPackJson(pack)));
  }
  const rules = (key: string): Rule[] =>
    (spec[key] as JsonObject[]).map((r, i) => ruleFromJson(r, `${key}[${i}]`));
  return new RuleEngine(rules('recognition'), rules('beforeTranslation'));
}

const engines = new Map<string, RuleEngine>(
  Object.entries(fixture.engines as JsonObject).map(([k, v]) => [k, engineOf(v as JsonObject)]),
);

describe('rules.json cases', () => {
  test.each(casesOf(fixture, 'cases').map(c => [c.name as string, c] as const))('%s', (_, c) => {
    const engine = engines.get(c.engine as string)!;
    const input = c.input as string;
    let out: string;
    switch (c.fn) {
      case 'fixRecognition':
        out = engine.fixRecognition(input);
        break;
      case 'forTranslation':
        out = engine.forTranslation(input);
        break;
      default:
        throw new Error(`unknown fn ${String(c.fn)}`);
    }
    expect(out).toBe(c.expected);
  });
});

describe('engine details', () => {
  test('\\d stays ASCII: an Arabic-Indic or fullwidth digit is not a digit', () => {
    const e = new RuleEngine([{id: 'd', pattern: '\\d+', template: '#', atClauseStart: false}], []);
    expect(e.fixRecognition('12 ١٢ １２')).toBe('# ١٢ １２');
  });

  test('a template group that does not exist or did not take part is empty', () => {
    const e = new RuleEngine(
      [{id: 't', pattern: 'a(b)?', template: '[$1|$2]', atClauseStart: false}],
      [],
    );
    expect(e.fixRecognition('a ab')).toBe('[|] [b|]');
  });

  test('a template is not a JS replacement string ($& and $$ stay literal)', () => {
    const e = new RuleEngine([{id: 't', pattern: 'x', template: '$&$$', atClauseStart: false}], []);
    expect(e.fixRecognition('x')).toBe('$&$$');
  });

  test('the bundled pack is the same as shared/languages/vi.json', () => {
    expect(bundledPack('vi')).toEqual(parseLanguagePack(readPackJson('vi')));
  });
});

// Not fixture-driven in the Dart suite either: properties of the bundled pack data.
describe('bundled patterns use the portable regex subset', () => {
  const syntax = fixture.portableSyntax as JsonObject;
  const forbidden = casesOf(syntax, 'forbidden').map(
    f => [f.name as string, new RegExp(f.regex as string)] as const,
  );

  test('the forbidden list catches what it names', () => {
    const samples: [string, string][] = [
      ['a++', 'possessive quantifier'],
      ['(?>a)', 'atomic group'],
      ['(?i)a', 'inline flags'],
      ['(?<x>a)', 'named group or backreference'],
      ['a\\z', 'anchors and escapes missing in JS'],
      ['[[:alpha:]]', 'POSIX class'],
      ['\\p{Lu}', 'Unicode class other than \\p{L}, \\p{N}, \\p{M}'],
    ];
    for (const [s, name] of samples) {
      expect(forbidden.filter(([, re]) => re.test(s)).map(([n]) => n)).toContain(name);
    }
    expect(
      forbidden.filter(([, re]) => re.test('(?<=xe )(?:a|b)*?\\d{3,}[\\d.,]+\\p{L}')),
    ).toEqual([]);
    expect(unboundedLookbehind('(?<=a+)b')).toBe(true);
    expect(unboundedLookbehind('(?<!(?:x|yz) )b')).toBe(false);
  });

  test.each(shippedPackCodes())('%s.json', code => {
    expect(syntax.lookbehind).toBe('bounded');
    const pack = parseLanguagePack(readPackJson(code));
    for (const r of [...pack.recognition, ...pack.beforeTranslation]) {
      for (const p of r.context === undefined ? [r.pattern] : [r.pattern, r.context]) {
        for (const [name, re] of forbidden) {
          expect([r.id, name, re.test(p)]).toEqual([r.id, name, false]);
        }
        expect([r.id, unboundedLookbehind(p)]).toEqual([r.id, false]);
      }
    }
  });

  test('every bundled rule has a unique, non-empty id', () => {
    const pack = parseLanguagePack(readPackJson('vi'));
    const ids = [...pack.recognition, ...pack.beforeTranslation].map(r => r.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids.every(id => id !== '')).toBe(true);
  });
});

describe('adversarial input', () => {
  // Timing: the subjects and limits are in the fixture, the clock is here.
  const adv = fixture.adversarial as JsonObject;
  const minLength = adv.minLength as number;
  const maxMsPerRule = adv.maxMsPerRule as number;
  const subjects = casesOf(adv, 'subjects').map(s => {
    let text = s.prefix as string;
    while (text.length < minLength) {
      text += s.unit as string;
    }
    return [s.name as string, text] as const;
  });
  const engine = engines.get('vi')!;
  const rules = [...engine.recognitionRules, ...engine.beforeRules];

  test('the vi pack has rules to time', () => {
    expect(rules.length).toBeGreaterThan(10);
    expect(subjects.every(([, t]) => t.length >= minLength)).toBe(true);
  });

  test.each(rules.map(r => [r.id, r] as const))(
    `%s finishes under ${maxMsPerRule} ms on each adversarial string`,
    (_, rule) => {
      for (const [name, text] of subjects) {
        const start = performance.now();
        rule.context?.test(text);
        text.replace(rule.regex, () => '');
        const ms = performance.now() - start;
        expect([rule.id, name, ms < maxMsPerRule]).toEqual([rule.id, name, true]);
      }
    },
  );

  test('the whole pipeline is fast too', () => {
    for (const [name, text] of subjects) {
      const start = performance.now();
      engine.forTranslation(text);
      const ms = performance.now() - start;
      expect([name, ms < (adv.maxMsPipeline as number)]).toEqual([name, true]);
    }
  });
});

/**
 * True when `pattern` has a lookbehind whose body can match text of unbounded length (an
 * unescaped `*`, `+` or `{n,}`), which ICU rejects. Same scan as the Dart test.
 */
function unboundedLookbehind(pattern: string): boolean {
  for (const start of pattern.matchAll(/\(\?<[=!]/g)) {
    let depth = 1;
    let i = start.index! + start[0].length;
    let body = '';
    while (i < pattern.length && depth > 0) {
      const c = pattern[i];
      if (c === '\\' && i + 1 < pattern.length) {
        body += '  '; // an escaped character never counts
        i += 2;
        continue;
      }
      if (c === '(') {
        depth++;
      }
      if (c === ')') {
        depth--;
      }
      if (depth > 0) {
        body += c;
      }
      i++;
    }
    if (/[*+]|\{\d*,\}/.test(body)) {
      return true;
    }
  }
  return false;
}
