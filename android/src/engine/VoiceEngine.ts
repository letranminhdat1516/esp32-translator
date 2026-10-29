/* eslint-disable no-bitwise -- base64 of PCM bytes */
// Port of app/lib/engine/voice_engine.dart (contract) and the message types of
// app/lib/engine/engine_api.g.dart (from app/pigeons/engine.dart). The message types keep their
// Dart names and fields so the Dart, Swift and TypeScript code read the same.
// ARCHITECTURE.md "Revision 2026-10-29" R3: Promises for calls, subscriptions for events.
import {Capabilities, RecognizerKind, recognizerKinds} from '../core/model';

// --- errors -------------------------------------------------------------------

export type EngineErrorCode = 'translateFailed' | 'notReady' | 'downloadFailed';
/** Every `EngineErrorCode`, in the Dart enum order. */
export const engineErrorCodes: readonly EngineErrorCode[] = [
  'translateFailed',
  'notReady',
  'downloadFailed',
];

/**
 * Typed failures of the voice engine. The native module rejects with an error whose `code` is one
 * of these names (`translate` → translateFailed, a call before `start` → notReady, `download` →
 * downloadFailed); the caller decides the fallback.
 */
export class EngineError extends Error {
  constructor(readonly code: EngineErrorCode, message: string = code) {
    super(message);
    this.name = 'EngineError';
  }

  /** The error named by a native code, or null when the code names none. */
  static fromCode(code: unknown, message?: string): EngineError | null {
    return typeof code === 'string' && (engineErrorCodes as readonly string[]).includes(code)
      ? new EngineError(code as EngineErrorCode, message)
      : null;
  }
}

// --- messages -----------------------------------------------------------------

export type MissingKind = 'speechModel' | 'translation' | 'ttsVoice';
export const missingKinds: readonly MissingKind[] = ['speechModel', 'translation', 'ttsVoice'];

export type AudioSessionKind = 'interrupted' | 'resumed' | 'routeChanged';
export const audioSessionKinds: readonly AudioSessionKind[] = ['interrupted', 'resumed', 'routeChanged'];

export type AudioRoute = 'headset' | 'phoneMic';
export const audioRoutes: readonly AudioRoute[] = ['headset', 'phoneMic'];

/** `finalText` is the "final" kind (Dart name, `final` being reserved there). */
export type MineKind = 'partial' | 'finalText';
export const mineKinds: readonly MineKind[] = ['partial', 'finalText'];

/** Recognizers for one language in wire form: `kinds` carries `RecognizerKind` names. */
export interface RecognizerEntryMsg {
  readonly language: string;
  readonly kinds: readonly string[];
}

/** Capabilities in wire form; `capabilitiesFromMsg` gives the model. */
export interface CapabilitiesMsg {
  readonly recognizers: readonly RecognizerEntryMsg[];
  readonly translatable: readonly string[];
  readonly vietnameseVoice: boolean;
}

/** Something to download before a pair can run. `from`/`to` are set only for `translation`. */
export interface MissingMsg {
  readonly kind: MissingKind;
  readonly language: string;
  readonly from?: string | null;
  readonly to?: string | null;
}

/** The pair of a session: `home` is always "vi"; `generation` tags the "their" side. */
export interface PairMsg {
  readonly home: string;
  readonly other: string;
  readonly generation: number;
}

/** The user's own speech (TurnAssembler input). Times in ms since the session started. */
export interface MineMsg {
  readonly kind: MineKind;
  readonly text: string;
  readonly startMs: number;
  readonly endMs: number;
}

/** A final result of the other person's speech; `confidence` null when the recognizer gives none. */
export interface TheirsMsg {
  readonly text: string;
  readonly confidence: number | null;
  readonly generation: number;
}

export interface AudioSessionMsg {
  readonly kind: AudioSessionKind;
  readonly route?: AudioRoute | null;
}

/** Download progress (0..1), completion or failure of one `MissingMsg`. */
export interface DownloadMsg {
  readonly item: MissingMsg;
  readonly progress: number;
  readonly done: boolean;
  readonly error: string | null;
}

/** Field equality of two `MissingMsg`s (an absent `from`/`to` equals null). */
export function missingEquals(a: MissingMsg, b: MissingMsg): boolean {
  return (
    a.kind === b.kind &&
    a.language === b.language &&
    (a.from ?? null) === (b.from ?? null) &&
    (a.to ?? null) === (b.to ?? null)
  );
}

/** Dart `CapabilitiesMsg.toModel`; throws on a recognizer name that is not a `RecognizerKind`. */
export function capabilitiesFromMsg(msg: CapabilitiesMsg): Capabilities {
  const recognizers: Record<string, RecognizerKind[]> = {};
  for (const entry of msg.recognizers) {
    recognizers[entry.language] = entry.kinds.map(name => {
      if (!(recognizerKinds as readonly string[]).includes(name)) {
        throw new Error(`unknown recognizer "${name}"`);
      }
      return name as RecognizerKind;
    });
  }
  return {
    recognizers,
    translatable: new Set(msg.translatable),
    vietnameseVoice: msg.vietnameseVoice,
  };
}

// --- PCM ------------------------------------------------------------------------

const base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/**
 * Base64 of `pcm` as 16-bit little-endian samples (Android and iOS are little-endian), honouring a
 * view's offset. This is how board PCM crosses the TurboModule bridge (`feedTheirAudio`).
 */
export function pcm16leBase64(pcm: Int16Array): string {
  const bytes = new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  let out = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out +=
      base64Alphabet[n >> 18] +
      base64Alphabet[(n >> 12) & 63] +
      base64Alphabet[(n >> 6) & 63] +
      base64Alphabet[n & 63];
  }
  const rest = bytes.length - i;
  if (rest === 1) {
    const n = bytes[i] << 16;
    out += base64Alphabet[n >> 18] + base64Alphabet[(n >> 12) & 63] + '==';
  } else if (rest === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out +=
      base64Alphabet[n >> 18] + base64Alphabet[(n >> 12) & 63] + base64Alphabet[(n >> 6) & 63] + '=';
  }
  return out;
}

// --- events -----------------------------------------------------------------------

/** Removes the subscription; calling it again does nothing. */
export type Unsubscribe = () => void;

/**
 * A small synchronous event emitter keyed by a map of event name → payload type. Handlers run in
 * subscription order on the emitting call; a handler that throws does not stop the others (the
 * first error is rethrown after all ran). Also used by `BoardLink` implementations.
 */
export class TypedEmitter<Events extends object> {
  private readonly handlers = new Map<keyof Events, Array<(payload: never) => void>>();

  on<K extends keyof Events>(event: K, handler: (payload: Events[K]) => void): Unsubscribe {
    const entry = handler as (payload: never) => void;
    const list = this.handlers.get(event) ?? [];
    list.push(entry);
    this.handlers.set(event, list);
    let active = true;
    return () => {
      if (!active) {
        return;
      }
      active = false;
      const current = this.handlers.get(event) ?? [];
      const i = current.indexOf(entry);
      if (i >= 0) {
        this.handlers.set(event, [...current.slice(0, i), ...current.slice(i + 1)]);
      }
    };
  }

  emit<K extends keyof Events>(event: K, payload: Events[K]): void {
    let failure: {error: unknown} | null = null;
    for (const handler of this.handlers.get(event) ?? []) {
      try {
        (handler as (p: Events[K]) => void)(payload);
      } catch (error) {
        failure ??= {error};
      }
    }
    if (failure) {
      throw failure.error;
    }
  }

  listenerCount(event: keyof Events): number {
    return this.handlers.get(event)?.length ?? 0;
  }

  removeAll(): void {
    this.handlers.clear();
  }
}

/** Event name → payload of the voice engine (the Dart streams). */
export interface VoiceEngineEvents {
  mine: MineMsg;
  theirs: TheirsMsg;
  /** Voice gate open (true) / closed (false), for ConversationActivity. */
  gate: boolean;
  ttsStart: number;
  ttsEnd: number;
  audioSession: AudioSessionMsg;
  download: DownloadMsg;
}

// --- the engine ---------------------------------------------------------------------

/**
 * The one native engine per platform: mic, voice gate, recognizers, offline translation and TTS.
 * Calls reject with `EngineError` for the failures the caller handles; other errors pass through.
 * Events are delivered to every subscriber registered at the time they are emitted.
 */
export interface VoiceEngine {
  /** Fast, no downloads; called at launch and after any download. `home` is the user's language ("vi"). */
  capabilities(home: string): Promise<Capabilities>;
  missing(pair: PairMsg): Promise<MissingMsg[]>;
  /** The `download` call (Dart name; the `download` event takes the plain name). Progress arrives as events. */
  downloadItem(item: MissingMsg): Promise<void>;
  /** Idempotent. `recognizerX` is a `RecognizerKind` name for the other language. */
  start(pair: PairMsg, recognizerX: string, hints: readonly string[]): Promise<void>;
  stop(): Promise<void>;
  micOn(on: boolean): Promise<void>;
  /** PCM from the board, 16-bit mono. */
  feedTheirAudio(pcm: Int16Array, sampleRate: number): Promise<void>;
  /** Rejects with `EngineError('translateFailed')` on failure; the caller decides the fallback. */
  translate(text: string, from: string, to: string): Promise<string>;
  /** `ttsStart(id)` and `ttsEnd(id)` follow. */
  speak(text: string, id: number): Promise<void>;
  stopSpeaking(): Promise<void>;
  /** No-op where unsupported. */
  setHints(hints: readonly string[]): Promise<void>;
  openTtsSettings(): Promise<void>;

  on<K extends keyof VoiceEngineEvents>(
    event: K,
    handler: (payload: VoiceEngineEvents[K]) => void,
  ): Unsubscribe;
}
