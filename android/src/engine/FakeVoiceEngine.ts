// Port of app/lib/engine/fake_voice_engine.dart: an in-memory VoiceEngine for tests. Every
// response is scriptable, every call is recorded, and tests push events with `emit`.
import {Capabilities} from '../core/model';
import {
  EngineError,
  MissingMsg,
  PairMsg,
  TypedEmitter,
  Unsubscribe,
  VoiceEngine,
  VoiceEngineEvents,
} from './VoiceEngine';

type CallName = Exclude<keyof VoiceEngine, 'on'>;

export class FakeVoiceEngine implements VoiceEngine {
  constructor(
    public capabilitiesResult: Capabilities = {
      recognizers: {},
      translatable: new Set(),
      vietnameseVoice: true,
    },
  ) {}

  /** Returned by `missing`; set per test. */
  missingResult: MissingMsg[] = [];
  /** Translations by source text. A text with no entry is returned unchanged. */
  readonly translations = new Map<string, string>();

  // Recorded calls, in order.
  readonly capabilitiesCalls: string[] = [];
  readonly missingCalls: PairMsg[] = [];
  readonly translateCalls: Array<{text: string; from: string; to: string}> = [];
  /** `speak` calls in order. */
  readonly spoken: Array<{text: string; id: number}> = [];
  readonly downloaded: MissingMsg[] = [];
  readonly starts: Array<{pair: PairMsg; recognizerX: string; hints: readonly string[]}> = [];
  readonly fed: Array<{pcm: Int16Array; sampleRate: number}> = [];
  readonly micStates: boolean[] = [];
  hints: readonly string[] = [];
  stopCount = 0;
  stopSpeakingCount = 0;
  openTtsSettingsCount = 0;

  private readonly events = new TypedEmitter<VoiceEngineEvents>();
  private readonly failures = new Map<CallName, unknown>();

  /** Makes the next `translate` reject with `EngineError('translateFailed')`. */
  failNextTranslate(): void {
    this.failNext('translate', new EngineError('translateFailed'));
  }

  /**
   * Makes the next call of `name` reject with `error`. A failed call is not recorded, except in
   * `translateCalls`, which keeps every request.
   */
  failNext(name: CallName, error: unknown): void {
    this.failures.set(name, error);
  }

  /** Delivers an event to the subscribers, as the native engine would. */
  emit<K extends keyof VoiceEngineEvents>(event: K, payload: VoiceEngineEvents[K]): void {
    this.events.emit(event, payload);
  }

  on<K extends keyof VoiceEngineEvents>(
    event: K,
    handler: (payload: VoiceEngineEvents[K]) => void,
  ): Unsubscribe {
    return this.events.on(event, handler);
  }

  /** Number of subscribers to `event` (to check that callers unsubscribe). */
  listenerCount(event: keyof VoiceEngineEvents): number {
    return this.events.listenerCount(event);
  }

  private async call<T>(name: CallName, body: () => T): Promise<T> {
    if (this.failures.has(name)) {
      const error = this.failures.get(name);
      this.failures.delete(name);
      throw error;
    }
    return body();
  }

  capabilities(home: string): Promise<Capabilities> {
    return this.call('capabilities', () => {
      this.capabilitiesCalls.push(home);
      return this.capabilitiesResult;
    });
  }

  missing(pair: PairMsg): Promise<MissingMsg[]> {
    return this.call('missing', () => {
      this.missingCalls.push(pair);
      return this.missingResult;
    });
  }

  downloadItem(item: MissingMsg): Promise<void> {
    return this.call('downloadItem', () => {
      this.downloaded.push(item);
    });
  }

  start(pair: PairMsg, recognizerX: string, hints: readonly string[]): Promise<void> {
    return this.call('start', () => {
      this.starts.push({pair, recognizerX, hints});
    });
  }

  stop(): Promise<void> {
    return this.call('stop', () => {
      this.stopCount++;
    });
  }

  micOn(on: boolean): Promise<void> {
    return this.call('micOn', () => {
      this.micStates.push(on);
    });
  }

  feedTheirAudio(pcm: Int16Array, sampleRate: number): Promise<void> {
    return this.call('feedTheirAudio', () => {
      this.fed.push({pcm, sampleRate});
    });
  }

  translate(text: string, from: string, to: string): Promise<string> {
    this.translateCalls.push({text, from, to});
    return this.call('translate', () => this.translations.get(text) ?? text);
  }

  speak(text: string, id: number): Promise<void> {
    return this.call('speak', () => {
      this.spoken.push({text, id});
    });
  }

  stopSpeaking(): Promise<void> {
    return this.call('stopSpeaking', () => {
      this.stopSpeakingCount++;
    });
  }

  setHints(hints: readonly string[]): Promise<void> {
    return this.call('setHints', () => {
      this.hints = hints;
    });
  }

  openTtsSettings(): Promise<void> {
    return this.call('openTtsSettings', () => {
      this.openTtsSettingsCount++;
    });
  }
}
