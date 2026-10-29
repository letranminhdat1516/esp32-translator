// Port of app/test/core/subtitle_translator_test.dart. Cases:
// shared/fixtures/subtitle_translator.json (see shared/fixtures/README.md).
// Waits use Jest fake timers (the Dart test waits in real time).
import {SubtitleTranslator} from '../src/core/subtitleTranslator';
import {JsonObject, casesOf, loadFixture} from './fixtures';

/** Upper-cases the text after a delay and records every request. */
class FakeTranslator {
  readonly requests: string[] = [];
  constructor(private readonly delayMs: number, private readonly failing: Set<string>) {}

  translate = async (text: string): Promise<string> => {
    this.requests.push(text);
    await new Promise<void>(resolve => setTimeout(resolve, this.delayMs));
    if (this.failing.has(text)) {
      throw new Error('cancelled');
    }
    return text.toUpperCase();
  };
}

const fixture = loadFixture('subtitle_translator');

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  jest.useRealTimers();
});

test('the fixture has every scenario', () => {
  expect(casesOf(fixture, 'scenarios')).toHaveLength(6);
});

describe('scenarios', () => {
  for (const c of casesOf(fixture, 'scenarios')) {
    test(c.name as string, async () => {
      const spec = c.translator as JsonObject;
      const fake = new FakeTranslator(
        spec.delayMs as number,
        new Set((spec.failing as string[] | undefined) ?? []),
      );
      const byTurn = new Map<number, string>();
      const st = new SubtitleTranslator({
        translate: fake.translate,
        onResult: (turn, text) => byTurn.set(turn, text),
      });
      const steps = casesOf(c, 'steps');
      expect(steps.length).toBeGreaterThan(0);
      for (const step of steps) {
        switch (step.op) {
          case 'partial':
            st.setPartial(step.text as string, step.turn as number);
            break;
          case 'final':
            st.addFinal(step.text as string, step.turn as number);
            break;
          case 'reset':
            st.reset();
            break;
          case 'wait':
            await jest.advanceTimersByTimeAsync(step.ms as number);
            break;
          default:
            throw new Error(`unknown op ${String(step.op)}`);
        }
      }
      const want = c.expect as JsonObject;
      // Every scenario checks something (a renamed key would check nothing).
      expect(
        ['results', 'emptyTurns', 'requestCounts', 'maxRequestLength', 'wordCounts'].some(
          k => k in want,
        ),
      ).toBe(true);
      expect(Object.keys(want).every(k =>
        ['results', 'emptyTurns', 'requestCounts', 'maxRequestLength', 'wordCounts'].includes(k),
      )).toBe(true);
      for (const [turn, text] of Object.entries((want.results as JsonObject | undefined) ?? {})) {
        expect({turn, text: byTurn.get(Number(turn))}).toEqual({turn, text});
      }
      for (const turn of (want.emptyTurns as number[] | undefined) ?? []) {
        expect({turn, text: byTurn.get(turn) ?? ''}).toEqual({turn, text: ''});
      }
      for (const r of casesOf(want, 'requestCounts')) {
        const n = fake.requests.filter(q => q === r.text).length;
        if (r.exactly != null) {
          expect({text: r.text, n}).toEqual({text: r.text, n: r.exactly});
        }
        if (r.max != null) {
          expect(n).toBeLessThanOrEqual(r.max as number);
        }
      }
      if (want.maxRequestLength != null) {
        const longest = fake.requests.reduce((a, q) => Math.max(a, q.length), 0);
        expect(longest).toBeLessThanOrEqual(want.maxRequestLength as number);
      }
      for (const [turn, count] of Object.entries((want.wordCounts as JsonObject | undefined) ?? {})) {
        const words = (byTurn.get(Number(turn)) ?? '').split(' ').filter(w => w !== '');
        expect(words.length).toBe(count);
      }
    });
  }
});

// Not fixture-driven: the injected scheduler and the log hook.

test('work starts after the synchronous burst, through the injected scheduler', async () => {
  const scheduled: Array<() => void> = [];
  const requests: string[] = [];
  const results: Array<[number, string]> = [];
  const st = new SubtitleTranslator({
    translate: async text => {
      requests.push(text);
      return text.toUpperCase();
    },
    onResult: (turn, text) => results.push([turn, text]),
    schedule: fn => scheduled.push(fn),
  });
  st.setPartial('một', 1);
  st.addFinal('một hai', 1);
  st.setPartial('ba', 1);
  expect(requests).toEqual([]);
  expect(scheduled).toHaveLength(1); // one loop for the whole burst
  scheduled[0]();
  await jest.advanceTimersByTimeAsync(0);
  // The final goes first; the stale partial "một" was dropped by addFinal.
  expect(requests).toEqual(['một hai', 'ba']);
  expect(results).toEqual([
    [1, 'MỘT HAI'],
    [1, 'MỘT HAI BA'],
  ]);
});

test('a failed translation is logged', async () => {
  const log: string[] = [];
  const st = new SubtitleTranslator({
    translate: async () => {
      throw new Error('boom');
    },
    onResult: () => {},
    log: message => log.push(message),
  });
  st.addFinal('abc', 1);
  await jest.advanceTimersByTimeAsync(0);
  expect(log).toEqual(['translate FAILED (3 chars): Error: boom']);
});

test('an exception from onResult is logged and the remaining jobs still run', async () => {
  const log: string[] = [];
  const results: Array<[number, string]> = [];
  const st = new SubtitleTranslator({
    translate: async text => text.toUpperCase(),
    onResult: (turn, text) => {
      results.push([turn, text]);
      if (text === 'MỘT') {
        throw new Error('listener broke');
      }
    },
    log: message => log.push(message),
  });
  st.addFinal('một', 1);
  st.addFinal('hai', 1);
  st.setPartial('ba', 1);
  await jest.advanceTimersByTimeAsync(0);
  expect(results).toEqual([
    [1, 'MỘT'],
    [1, 'MỘT HAI'],
    [1, 'MỘT HAI BA'],
  ]);
  expect(log).toEqual(['onResult FAILED (turn 1): Error: listener broke']);
  // The loop is not stuck: new work still runs.
  st.addFinal('bốn', 2);
  await jest.advanceTimersByTimeAsync(0);
  expect(results[results.length - 1]).toEqual([2, 'BỐN']);
});
