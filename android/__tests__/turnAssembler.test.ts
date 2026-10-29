// Port of app/test/core/turn_assembler_test.dart. Cases: shared/fixtures/turn_assembler.json
// and the recordings shared/fixtures/*.jsonl (see shared/fixtures/README.md).
import fs from 'fs';
import path from 'path';

import {Rule, parseLanguagePack} from '../src/core/model';
import {TranscriptEvent, TurnAssembler} from '../src/core/turnAssembler';
import {JsonObject, casesOf, loadFixture, readPackJson, sharedDir} from './fixtures';

const fixture = loadFixture('turn_assembler');
const defaults = fixture.defaults as JsonObject;
const t0 = Date.UTC(2026, 0, 1);

/**
 * A pack's `fixRecognition` (shared/fixtures/README.md, rules.json section), test-only:
 * the TS RuleEngine is track T1b (android/src/core/ruleEngine.ts, not in this worktree).
 * When both tracks are merged this can become `RuleEngine.forPack(pack).fixRecognition`.
 */
function fixRecognitionOf(code: string): (text: string) => string {
  const rules = parseLanguagePack(readPackJson(code)).recognition;
  if (rules.length === 0) {
    return text => text;
  }
  const compiled = rules.map((rule: Rule) => {
    const start = rule.atClauseStart ? '(^|[,.!?])\\s*' : '(?<![\\p{L}\\p{N}])';
    return {
      regex: new RegExp(`${start}(?:${rule.pattern})(?![\\p{L}\\p{N}])`, 'giu'),
      template: rule.template,
      context: rule.context == null ? null : new RegExp(rule.context, 'iu'),
    };
  });
  return text => {
    let out = text.normalize('NFC');
    for (const r of compiled) {
      if (r.context && !r.context.test(out)) {
        continue;
      }
      out = out.replace(r.regex, (...args: unknown[]) => {
        const groups = args.slice(1, args.findIndex(a => typeof a === 'number')) as Array<
          string | undefined
        >;
        return r.template.replace(/\$(\d)/g, (_, n: string) => groups[Number(n) - 1] ?? '');
      });
    }
    return out;
  };
}

function assemblerOf(c: JsonObject): TurnAssembler {
  const config = {...defaults, ...((c.config as JsonObject | undefined) ?? {})};
  const fixPack = config.fixLoanwords as string | undefined;
  return new TurnAssembler({
    turnGapMs: config.turnGapMs as number,
    staleGapMs: config.staleGapMs as number,
    maxCharacters: config.maxCharacters as number,
    maxDurationMs: config.maxDurationMs as number,
    fixLoanwords: fixPack == null ? undefined : fixRecognitionOf(fixPack),
  });
}

function eventOf(kind: string, text: string): TranscriptEvent {
  if (kind === 'partial') {
    return {kind: 'partial', text};
  }
  if (kind === 'final') {
    return {kind: 'final', text};
  }
  throw new Error(`unknown kind ${kind}`);
}

test('the fixture has every scenario and replay', () => {
  expect(casesOf(fixture, 'scenarios')).toHaveLength(6);
  expect(casesOf(fixture, 'replays')).toHaveLength(2);
});

describe('scenarios', () => {
  for (const c of casesOf(fixture, 'scenarios')) {
    test(c.name as string, () => {
      const a = assemblerOf(c);
      const ids = new Set<number>();
      const steps = casesOf(c, 'steps');
      expect(steps.length).toBeGreaterThan(0);
      steps.forEach((step, i) => {
        if (step.kind === 'reset') {
          a.reset();
        } else {
          const change = a.handle(
            eventOf(step.kind as string, step.text as string),
            t0 + (step.atMs as number),
          );
          if ('change' in step) {
            expect({step: i, change}).toEqual({step: i, change: step.change});
          }
        }
        if ('turnText' in step) {
          expect({step: i, text: a.turn?.text}).toEqual({step: i, text: step.turnText});
        }
        if (step.turnIsNull === true) {
          expect(a.turn).toBeNull();
        }
        if (a.turn != null) {
          ids.add(a.turn.id);
        }
        if (c.maxTurnTextLength != null) {
          // Dart String.length: UTF-16 code units, as in the reference test.
          expect(a.turn!.text.length).toBeLessThanOrEqual(c.maxTurnTextLength as number);
        }
      });
      if (c.minDistinctTurns != null) {
        expect(ids.size).toBeGreaterThanOrEqual(c.minDistinctTurns as number);
      }
    });
  }
});

describe('recorded replays', () => {
  for (const c of casesOf(fixture, 'replays')) {
    test(c.name as string, () => {
      const a = assemblerOf(c);
      const lines = new Map<number, string>();
      const records = fs
        .readFileSync(path.join(sharedDir, 'fixtures', c.recording as string), 'utf8')
        .split('\n')
        .filter(l => l.trim() !== '');
      expect(records.length).toBeGreaterThan(0);
      for (const line of records) {
        const d = JSON.parse(line) as {t: number; kind: string; text: string};
        // Whole microseconds, as the Dart test's DateTime.
        const now = t0 + Math.round(d.t * 1e6) / 1000;
        const change = a.handle(eventOf(d.kind, d.text), now);
        const turn = a.turn;
        if (change == null || turn == null) {
          continue;
        }
        lines.set(turn.id, turn.text); // Map keeps first-insertion order.
      }
      expect((c.expectLines as string[]).length).toBeGreaterThan(0);
      expect([...lines.values()]).toEqual(c.expectLines);
    });
  }
});

// Not fixture-driven: the cap counts grapheme clusters, not UTF-16 units.
test('the length cap counts grapheme clusters (README turn_assembler rule)', () => {
  // "e" + combining acute: 2 UTF-16 units, 1 grapheme.
  const word = 'é';
  const a = new TurnAssembler({maxCharacters: 3});
  a.handle({kind: 'final', text: word.repeat(3)}, t0); // 3 graphemes, 6 units: not over
  expect(a.handle({kind: 'final', text: 'x'}, t0 + 100)).toEqual({started: false, finalText: 'x'});
  // Now "ééé x" = 5 graphemes > 3: closed, the next event opens turn 2.
  expect(a.handle({kind: 'partial', text: 'y'}, t0 + 200)).toEqual({started: true, finalText: null});
  expect(a.turn?.id).toBe(2);
});

test('the grapheme splitter is injectable', () => {
  const a = new TurnAssembler({maxCharacters: 3, graphemes: text => Array.from(text)});
  a.handle({kind: 'final', text: 'éé'}, t0); // 4 code points with this splitter
  expect(a.handle({kind: 'partial', text: 'y'}, t0 + 100)).toEqual({started: true, finalText: null});
});

test('turn ids are never reused across reset', () => {
  const a = new TurnAssembler();
  a.handle({kind: 'final', text: 'một'}, t0);
  a.reset();
  expect(a.turn).toBeNull();
  a.handle({kind: 'final', text: 'hai'}, t0 + 100);
  expect(a.turn).toEqual({id: 2, finals: ['hai'], partial: '', text: 'hai'});
});
