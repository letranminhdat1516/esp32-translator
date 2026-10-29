// Port of app/lib/engine/session_machine.dart: the session state machine (ARCHITECTURE.md §3).
// Pure and immutable. Contract: shared/fixtures/session_machine.json (states and events have the
// fixture's JSON shape).
import {MissingMsg, missingEquals} from './VoiceEngine';

export type SessionState =
  | {readonly type: 'loading'}
  | {readonly type: 'choosing'; readonly reason: string | null}
  | {readonly type: 'checking'; readonly code: string}
  | {
      readonly type: 'needsDownload';
      readonly code: string;
      readonly missing: readonly MissingMsg[];
      readonly error: string | null;
    }
  | {readonly type: 'downloading'; readonly code: string}
  | {readonly type: 'preparing'; readonly code: string; readonly restarts: number}
  | {readonly type: 'running'; readonly code: string; readonly restarts: number}
  | {readonly type: 'switching'; readonly from: string; readonly to: string}
  | {readonly type: 'failed'; readonly code: string; readonly reason: string};

export type SessionEvent =
  | {readonly type: 'catalogReady'; readonly saved: string | null; readonly offered: ReadonlySet<string>}
  | {readonly type: 'picked'; readonly code: string}
  | {readonly type: 'checked'; readonly missing: readonly MissingMsg[]}
  | {readonly type: 'downloadTapped'}
  | {readonly type: 'downloadDone'}
  | {readonly type: 'downloadFailed'; readonly error: string}
  | {readonly type: 'started'}
  | {readonly type: 'startFailed'; readonly reason: string}
  | {readonly type: 'recognizerDied'}
  | {readonly type: 'retry'};

/** A state plus the generation of "their" side; late results with an old generation are dropped. */
export interface Session {
  readonly state: SessionState;
  readonly generation: number;
}

function afterCheck(code: string, missing: readonly MissingMsg[]): SessionState {
  return missing.length === 0
    ? {type: 'preparing', code, restarts: 0}
    : {type: 'needsDownload', code, missing, error: null};
}

/** Pure transition function. Events not listed for a state return the state itself. */
export function next(s: SessionState, e: SessionEvent): SessionState {
  switch (s.type) {
    case 'loading':
      if (e.type === 'catalogReady') {
        if (e.saved === null) {
          return {type: 'choosing', reason: null};
        }
        return e.offered.has(e.saved)
          ? {type: 'checking', code: e.saved}
          : {type: 'choosing', reason: 'unavailable'};
      }
      return s;
    case 'choosing':
      return e.type === 'picked' ? {type: 'checking', code: e.code} : s;
    case 'checking':
      return e.type === 'checked' ? afterCheck(s.code, e.missing) : s;
    case 'needsDownload':
      if (e.type === 'picked') {
        return {type: 'checking', code: e.code};
      }
      return e.type === 'downloadTapped' ? {type: 'downloading', code: s.code} : s;
    case 'downloading':
      if (e.type === 'downloadDone') {
        // Re-check: one download may not cover every missing item.
        return {type: 'checking', code: s.code};
      }
      return e.type === 'downloadFailed'
        ? {type: 'needsDownload', code: s.code, missing: [], error: e.error}
        : s;
    case 'preparing':
      if (e.type === 'started') {
        return {type: 'running', code: s.code, restarts: s.restarts};
      }
      return e.type === 'startFailed' ? {type: 'failed', code: s.code, reason: e.reason} : s;
    case 'running':
      if (e.type === 'picked') {
        return e.code === s.code ? s : {type: 'switching', from: s.code, to: e.code};
      }
      if (e.type === 'recognizerDied') {
        return s.restarts === 0
          ? {type: 'preparing', code: s.code, restarts: 1}
          : {type: 'failed', code: s.code, reason: 'recognizer stopped'};
      }
      return s;
    case 'switching':
      return e.type === 'checked' ? afterCheck(s.to, e.missing) : s;
    case 'failed':
      if (e.type === 'picked') {
        return {type: 'checking', code: e.code};
      }
      return e.type === 'retry' ? {type: 'checking', code: s.code} : s;
  }
}

/** Applies `e`; increments the generation when a switch begins (a new, different `switching`). */
export function advance(s: Session, e: SessionEvent): Session {
  const n = next(s.state, e);
  const entered = n.type === 'switching' && !sessionStateEquals(n, s.state);
  return {state: n, generation: entered ? s.generation + 1 : s.generation};
}

/** Value equality of two states (`missing` compared element by element). */
export function sessionStateEquals(a: SessionState, b: SessionState): boolean {
  if (a.type !== b.type) {
    return false;
  }
  switch (a.type) {
    case 'loading':
      return true;
    case 'needsDownload': {
      const o = b as typeof a;
      return (
        a.code === o.code &&
        a.error === o.error &&
        a.missing.length === o.missing.length &&
        a.missing.every((m, i) => missingEquals(m, o.missing[i]))
      );
    }
    default: {
      const x = a as unknown as Record<string, unknown>;
      const y = b as unknown as Record<string, unknown>;
      const keys = Object.keys(x);
      return keys.length === Object.keys(y).length && keys.every(k => x[k] === y[k]);
    }
  }
}
