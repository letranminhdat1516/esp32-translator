// Port of app/lib/core/turn_assembler.dart. Contract: shared/fixtures/turn_assembler.json.
import {graphemes} from '../board/protocol';

/** Splits text into grapheme clusters. */
export type Graphemes = (text: string) => string[];

/**
 * One result of a speech recognizer. `partial` may still change (each one replaces the
 * previous volatile text); `final` will not. `confidence` is the mean word confidence (0..1)
 * when the engine reports it.
 */
export type TranscriptEvent =
  | {readonly kind: 'partial'; readonly text: string}
  | {readonly kind: 'final'; readonly text: string; readonly confidence?: number};

/** The finalized phrases so far plus the current volatile (partial) text, loanwords fixed. */
export interface Turn {
  readonly id: number;
  readonly finals: readonly string[];
  readonly partial: string;
  /** Finals then partial, empty parts skipped, joined by one space. */
  readonly text: string;
}

function makeTurn(id: number, finals: readonly string[], partial: string): Turn {
  const text = [...finals, partial].filter(s => s !== '').join(' ');
  return {id, finals, partial, text};
}

/** What one event did to the turn. */
export interface TurnChange {
  /** This event opened a new turn. */
  readonly started: boolean;
  /** A phrase finalized by this event (already appended to `turn.finals`). */
  readonly finalText: string | null;
}

export interface TurnAssemblerOptions {
  /** A pause longer than this (after a final phrase) starts a new turn. */
  turnGapMs?: number;
  /** If a volatile phrase is never finalized, give up waiting after this long. */
  staleGapMs?: number;
  /** A turn longer than this (grapheme clusters) ends at its next final phrase. */
  maxCharacters?: number;
  /** A turn older than this ends at its next final phrase. */
  maxDurationMs?: number;
  /** Recognition fix-up applied to every event's text (the rule engine's `fixRecognition`). */
  fixLoanwords?: (text: string) => string;
  /** Grapheme splitter for the length cap (default: protocol.ts `graphemes`). */
  graphemes?: Graphemes;
}

/**
 * Builds the "You say" turns from the Vietnamese recognizer's events.
 *
 * A new turn (a fresh subtitle screen) starts only after the wearer has really paused: the last
 * phrase is final and nothing has arrived for `turnGapMs`. While a phrase is still volatile the
 * turn never splits (only after `staleGapMs`). A turn over `maxCharacters` or `maxDurationMs`
 * ends at its next final phrase.
 *
 * Time (milliseconds) comes in with each event, so it is unit-tested without a clock.
 */
export class TurnAssembler {
  readonly turnGapMs: number;
  readonly staleGapMs: number;
  readonly maxCharacters: number;
  readonly maxDurationMs: number;
  private readonly fixLoanwords: (text: string) => string;
  private readonly graphemes: Graphemes;

  private current: Turn | null = null;
  private lastEventMs: number | null = null;
  private turnStartMs = 0;
  private closeTurn = false;
  private nextId = 1;

  constructor(options: TurnAssemblerOptions = {}) {
    this.turnGapMs = options.turnGapMs ?? 2000;
    this.staleGapMs = options.staleGapMs ?? 10_000;
    this.maxCharacters = options.maxCharacters ?? 600;
    this.maxDurationMs = options.maxDurationMs ?? 60_000;
    this.fixLoanwords = options.fixLoanwords ?? (s => s);
    this.graphemes = options.graphemes ?? graphemes;
  }

  get turn(): Turn | null {
    return this.current;
  }

  /** Forgets the current turn (history cleared); the next event starts a new one. */
  reset(): void {
    this.current = null;
    this.closeTurn = false;
  }

  /** Applies one recognizer event; returns null when nothing changed. */
  handle(event: TranscriptEvent, nowMs: number): TurnChange | null {
    const text = this.fixLoanwords(event.text.trim());

    if (text === '') {
      // An empty result clears the volatile text (the phrase was dropped or is now final).
      const t = this.current;
      if (t === null || t.partial === '') {
        return null;
      }
      this.current = makeTurn(t.id, t.finals, '');
      return {started: false, finalText: null};
    }

    let started = false;
    // No earlier event counts as an infinite pause (Swift: distantPast).
    const quiet = this.lastEventMs === null ? null : nowMs - this.lastEventMs;
    const pending = (this.current?.partial ?? '') !== '';
    if (
      this.current === null ||
      (!pending && (quiet === null || quiet > this.turnGapMs || this.closeTurn)) ||
      quiet === null ||
      quiet > this.staleGapMs
    ) {
      this.current = makeTurn(this.nextId, [], '');
      this.nextId += 1;
      this.turnStartMs = nowMs;
      this.closeTurn = false;
      started = true;
    }
    this.lastEventMs = nowMs;

    const turn = this.current;
    if (event.kind === 'partial') {
      this.current = makeTurn(turn.id, turn.finals, text);
      return {started, finalText: null};
    }
    const next = makeTurn(turn.id, [...turn.finals, text], '');
    this.current = next;
    this.closeTurn =
      this.graphemes(next.text).length > this.maxCharacters ||
      nowMs - this.turnStartMs > this.maxDurationMs;
    return {started, finalText: text};
  }
}
