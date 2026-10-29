// Port of app/lib/core/conversation_activity.dart. Contract:
// shared/fixtures/conversation_activity.json.

export type ActivityState = 'idle' | 'active';

export type ActivityEvent =
  /** An audio packet from the board mic (English speech). */
  | 'boardAudio'
  /** The wearer started speaking (VoiceGate; only heard while a conversation holds the mic). */
  | 'gateOpen'
  /** The wearer stopped speaking. */
  | 'gateClosed'
  /** The app started speaking a translation into the earbuds. */
  | 'ttsStart'
  /** The app finished speaking a translation. */
  | 'ttsEnd'
  /** A tap: the board mic turned on, or the start control in the app. */
  | 'userStart'
  /** The stop control in the app. */
  | 'userStop'
  /** The audio session was taken away for good (an interruption that should not resume). */
  | 'stop'
  /** Periodic check of the idle timeout. */
  | 'tick';

export const activityEvents: readonly ActivityEvent[] = [
  'boardAudio',
  'gateOpen',
  'gateClosed',
  'ttsStart',
  'ttsEnd',
  'userStart',
  'userStop',
  'stop',
  'tick',
];

/** What the engine must do with the mic and the audio session. */
export type ActivityTransition = 'start' | 'stop';

/**
 * Decides when the app holds the earbuds mic: only during a conversation.
 *
 * While idle the app releases the mic and the audio session, so other apps play normally. A
 * conversation starts with the board streaming English, a translation to speak, or a tap. The
 * wearer's voice cannot start one (the earbuds mic is off while idle); `gateOpen` only keeps a
 * running conversation alive. After `idleTimeoutMs` with nobody speaking (no board audio, gate
 * closed, nothing being spoken) it ends.
 *
 * If the engine cannot take the mic (`startFailed`), the conversation goes back to idle and
 * automatic events don't retry for `retryDelayMs`; a tap always retries. A stop tap
 * (`userStop`) ends the conversation and keeps it off until the next tap.
 *
 * Pure value logic; time (epoch milliseconds) comes in with each event.
 */
export class ConversationActivity {
  readonly idleTimeoutMs: number;
  readonly retryDelayMs: number;

  private stateValue: ActivityState = 'idle';
  // ±Infinity stand in for Swift's distantPast / distantFuture.
  private lastSpeechMs = -Infinity;
  private gateIsOpen = false;
  private speaking = false;
  /** After a failed start (or a stop tap), automatic events don't start a conversation before this. */
  private noAutoStartUntilMs = -Infinity;

  constructor(options: {idleTimeoutMs?: number; retryDelayMs?: number} = {}) {
    this.idleTimeoutMs = options.idleTimeoutMs ?? 600_000;
    this.retryDelayMs = options.retryDelayMs ?? 30_000;
  }

  get state(): ActivityState {
    return this.stateValue;
  }

  get lastSpeech(): number {
    return this.lastSpeechMs;
  }

  get isActive(): boolean {
    return this.stateValue === 'active';
  }

  /** Applies one event; returns a transition when the state changes, else null. */
  handle(event: ActivityEvent, nowMs: number): ActivityTransition | null {
    switch (event) {
      case 'userStart':
        this.noAutoStartUntilMs = -Infinity;
        return this.markSpeech(nowMs);
      case 'boardAudio':
        return this.markSpeech(nowMs);
      case 'gateOpen':
        this.gateIsOpen = true;
        return this.markSpeech(nowMs);
      case 'ttsStart':
        this.speaking = true;
        return this.markSpeech(nowMs);
      case 'gateClosed':
        this.gateIsOpen = false;
        if (this.stateValue === 'active') {
          this.lastSpeechMs = nowMs;
        }
        return null;
      case 'ttsEnd':
        this.speaking = false;
        if (this.stateValue === 'active') {
          this.lastSpeechMs = nowMs;
        }
        return null;
      case 'stop':
        return this.goIdle();
      case 'userStop':
        this.noAutoStartUntilMs = Infinity;
        return this.goIdle();
      case 'tick':
        if (
          this.stateValue !== 'active' ||
          this.gateIsOpen ||
          this.speaking ||
          nowMs - this.lastSpeechMs < this.idleTimeoutMs
        ) {
          return null;
        }
        return this.goIdle();
    }
  }

  /**
   * The engine could not take the mic after `start`: back to idle without a `stop` transition
   * (nothing to release), and no automatic restart for `retryDelayMs`.
   */
  startFailed(nowMs: number): void {
    this.stateValue = 'idle';
    this.gateIsOpen = false;
    this.speaking = false;
    this.noAutoStartUntilMs = nowMs + this.retryDelayMs;
  }

  private markSpeech(nowMs: number): ActivityTransition | null {
    this.lastSpeechMs = nowMs;
    if (this.stateValue !== 'idle' || nowMs < this.noAutoStartUntilMs) {
      return null;
    }
    this.stateValue = 'active';
    return 'start';
  }

  private goIdle(): ActivityTransition | null {
    this.gateIsOpen = false;
    this.speaking = false;
    if (this.stateValue !== 'active') {
      return null;
    }
    this.stateValue = 'idle';
    return 'stop';
  }
}
