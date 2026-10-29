// Port of app/test/engine/session_machine_test.dart. Cases: shared/fixtures/session_machine.json.
import {MissingMsg, missingKinds, MissingKind} from '../src/engine/VoiceEngine';
import {
  SessionEvent,
  SessionState,
  advance,
  next,
  sessionStateEquals,
} from '../src/engine/sessionMachine';
import {JsonObject, casesOf, loadFixture} from './fixtures';

const fixture = loadFixture('session_machine');

function missingOf(json: unknown): MissingMsg[] {
  return (json as JsonObject[]).map(m => ({
    kind: m.kind as MissingKind,
    language: m.language as string,
    from: (m.from as string | undefined) ?? null,
    to: (m.to as string | undefined) ?? null,
  }));
}

function stateOf(j: JsonObject): SessionState {
  switch (j.type) {
    case 'loading':
      return {type: 'loading'};
    case 'choosing':
      return {type: 'choosing', reason: (j.reason as string | null | undefined) ?? null};
    case 'checking':
      return {type: 'checking', code: j.code as string};
    case 'needsDownload':
      return {
        type: 'needsDownload',
        code: j.code as string,
        missing: missingOf(j.missing),
        error: (j.error as string | null | undefined) ?? null,
      };
    case 'downloading':
      return {type: 'downloading', code: j.code as string};
    case 'preparing':
      return {type: 'preparing', code: j.code as string, restarts: (j.restarts as number) ?? 0};
    case 'running':
      return {type: 'running', code: j.code as string, restarts: (j.restarts as number) ?? 0};
    case 'switching':
      return {type: 'switching', from: j.from as string, to: j.to as string};
    case 'failed':
      return {type: 'failed', code: j.code as string, reason: j.reason as string};
  }
  throw new Error(`unknown state ${String(j.type)}`);
}

function eventOf(j: JsonObject): SessionEvent {
  switch (j.type) {
    case 'catalogReady':
      return {
        type: 'catalogReady',
        saved: (j.saved as string | null) ?? null,
        offered: new Set(j.offered as string[]),
      };
    case 'picked':
      return {type: 'picked', code: j.code as string};
    case 'checked':
      return {type: 'checked', missing: missingOf(j.missing)};
    case 'downloadTapped':
    case 'downloadDone':
    case 'started':
    case 'recognizerDied':
    case 'retry':
      return {type: j.type};
    case 'downloadFailed':
      return {type: 'downloadFailed', error: j.error as string};
    case 'startFailed':
      return {type: 'startFailed', reason: j.reason as string};
  }
  throw new Error(`unknown event ${String(j.type)}`);
}

test('missing kinds', () => {
  expect(missingKinds).toEqual(fixture.missingKinds);
});

describe('transition table', () => {
  for (const c of casesOf(fixture, 'transitions')) {
    test(c.name as string, () => {
      const got = next(stateOf(c.state as JsonObject), eventOf(c.event as JsonObject));
      const want = stateOf(c.expected as JsonObject);
      expect(got).toEqual(want);
      expect(sessionStateEquals(got, want)).toBe(true);
    });
  }
});

describe('generation', () => {
  for (const c of casesOf(fixture, 'generations')) {
    test(c.name as string, () => {
      const start = c.start as JsonObject;
      let s = {state: stateOf(start.state as JsonObject), generation: start.generation as number};
      casesOf(c, 'steps').forEach((step, i) => {
        s = advance(s, eventOf(step.event as JsonObject));
        expect({step: i, state: s.state}).toEqual({step: i, state: stateOf(step.state as JsonObject)});
        expect({step: i, generation: s.generation}).toEqual({step: i, generation: step.generation});
      });
    });
  }
});

// Not fixture-driven: value equality.
describe('value equality', () => {
  const miss = (language = 'ja'): MissingMsg => ({kind: 'speechModel', language});

  test('needsDownload compares missing by fields', () => {
    const nd = (m: MissingMsg[]): SessionState => ({
      type: 'needsDownload',
      code: 'ja',
      missing: m,
      error: null,
    });
    expect(sessionStateEquals(nd([miss()]), nd([miss()]))).toBe(true);
    expect(sessionStateEquals(nd([miss()]), nd([miss('fr')]))).toBe(false);
    expect(sessionStateEquals(nd([miss()]), nd([miss(), miss()]))).toBe(false);
    // An absent from/to equals null.
    expect(
      sessionStateEquals(nd([miss()]), nd([{kind: 'speechModel', language: 'ja', from: null, to: null}])),
    ).toBe(true);
  });

  test('different state types are not equal', () => {
    expect(
      sessionStateEquals({type: 'preparing', code: 'ja', restarts: 0}, {type: 'running', code: 'ja', restarts: 0}),
    ).toBe(false);
    expect(
      sessionStateEquals({type: 'running', code: 'ja', restarts: 0}, {type: 'running', code: 'ja', restarts: 1}),
    ).toBe(false);
  });

  test('next returns the same object for an unlisted event', () => {
    const s: SessionState = {type: 'running', code: 'ja', restarts: 0};
    expect(next(s, {type: 'retry'})).toBe(s);
    expect(next(s, {type: 'picked', code: 'ja'})).toBe(s);
  });
});
