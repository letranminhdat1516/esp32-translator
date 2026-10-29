// Port of app/lib/core/subtitle_translator.dart. Contract:
// shared/fixtures/subtitle_translator.json.

class TurnState {
  /** Translation per final phrase; null until translated (then the placeholder is shown). */
  readonly finals: Array<string | null> = [];
  readonly placeholders: string[] = [];
  partialSource = '';
  partial = '';

  get text(): string {
    const parts = [...this.finals.map((f, i) => f ?? this.placeholders[i]), this.partial];
    return parts.filter(s => s !== '').join(' ');
  }
}

interface FinalJob {
  readonly turn: number;
  readonly index: number;
  readonly text: string;
}

export interface SubtitleTranslatorOptions {
  /** The translator (the engine's in the app, a stub in tests). May throw. */
  translate: (text: string) => Promise<string>;
  /** Every change of a turn's translation. */
  onResult: (turn: number, translation: string) => void;
  log?: (message: string) => void;
  /**
   * Runs the work loop after the caller's synchronous burst (default: a microtask, like Dart's
   * `scheduleMicrotask` / a Swift Task).
   */
  schedule?: (work: () => void) => void;
}

const microtask = (work: () => void) => {
  Promise.resolve().then(work);
};

/**
 * Live subtitles for the "You say" turns: the translation of what the wearer says.
 *
 * Each finalized phrase is translated once, in order, and kept; only the current volatile
 * phrase is re-translated as it changes (latest wins, stale requests are dropped). A turn's
 * translation is the finals' translations followed by the volatile one, so every request is one
 * phrase between pauses and never grows with the turn.
 *
 * A translation that throws keeps, for a final, the translation of its volatile version.
 */
export class SubtitleTranslator {
  private readonly translate: (text: string) => Promise<string>;
  private readonly onResult: (turn: number, translation: string) => void;
  private readonly log?: (message: string) => void;
  private readonly schedule: (work: () => void) => void;

  private turns = new Map<number, TurnState>();
  private finalJobs: FinalJob[] = [];
  private partialJob: {turn: number; text: string} | null = null;
  private running = false;

  constructor(options: SubtitleTranslatorOptions) {
    this.translate = options.translate;
    this.onResult = options.onResult;
    this.log = options.log;
    this.schedule = options.schedule ?? microtask;
  }

  /** A finalized phrase of `turn` (text already prepared for the translator). */
  addFinal(text: string, turn: number): void {
    const state = this.turns.get(turn) ?? new TurnState();
    state.finals.push(null);
    // Until its translation arrives, the phrase keeps showing its volatile version's translation.
    state.placeholders.push(state.partial);
    state.partial = '';
    state.partialSource = '';
    if (this.partialJob?.turn === turn) {
      this.partialJob = null;
    }
    if (text === '') {
      // Nothing to translate (e.g. the phrase was only "em ơi").
      state.finals[state.finals.length - 1] = '';
      this.turns.set(turn, state);
      this.onResult(turn, state.text);
      return;
    }
    this.turns.set(turn, state);
    this.finalJobs.push({turn, index: state.finals.length - 1, text});
    // Keep only the last few turns (late results for older lines are dropped).
    for (const key of [...this.turns.keys()]) {
      if (key <= turn - 3) {
        this.turns.delete(key);
      }
    }
    this.run();
  }

  /** Drops every turn and pending request (history cleared). */
  reset(): void {
    this.turns.clear();
    this.finalJobs = [];
    this.partialJob = null;
  }

  /** The current volatile phrase of `turn` (empty: none). */
  setPartial(text: string, turn: number): void {
    const state = this.turns.get(turn) ?? new TurnState();
    if (text === state.partialSource) {
      return;
    }
    state.partialSource = text;
    if (text === '') {
      state.partial = '';
      this.partialJob = null;
      this.turns.set(turn, state);
      this.onResult(turn, state.text);
      return;
    }
    this.turns.set(turn, state);
    this.partialJob = {turn, text};
    this.run();
  }

  private run(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    // Starts after the caller's synchronous calls: a burst of setPartial/addFinal is seen as a
    // whole (finals first).
    this.schedule(() => {
      this.loop().catch(() => {});
    });
  }

  private async loop(): Promise<void> {
    try {
      while (true) {
        const finalJob = this.finalJobs.shift();
        if (finalJob !== undefined) {
          const translation = await this.translated(finalJob.text);
          const state = this.turns.get(finalJob.turn);
          if (state === undefined || finalJob.index >= state.finals.length) {
            continue;
          }
          state.finals[finalJob.index] = translation ?? state.placeholders[finalJob.index];
          this.onResult(finalJob.turn, state.text);
        } else if (this.partialJob !== null) {
          const job = this.partialJob;
          this.partialJob = null;
          const translation = await this.translated(job.text);
          // Drop it if the phrase changed or was finalized meanwhile.
          const state = this.turns.get(job.turn);
          if (state === undefined || state.partialSource !== job.text || translation === null) {
            continue;
          }
          state.partial = translation;
          this.onResult(job.turn, state.text);
        } else {
          break;
        }
      }
    } finally {
      this.running = false;
    }
  }

  private async translated(text: string): Promise<string | null> {
    try {
      return await this.translate(text);
    } catch (e) {
      this.log?.(`translate FAILED (${text.length} chars): ${String(e)}`);
      return null;
    }
  }
}
