// TurboModule codegen spec of the Kotlin voice engine (VoiceEngineModule, track T4), plus
// `NativeVoiceEngineAdapter`, which implements `VoiceEngine` over it.
//
// Codegen (`codegenConfig` in package.json: VoiceEngineSpec, package vn.cicca.livetranslator.engine)
// reads the `Spec` interface below and generates `NativeVoiceEngineSpec` for Kotlin. Wire rules:
// - Same calls as app/pigeons/engine.dart, with `capabilities(home)` (home passed from JS, R3).
//   The download call is named `download` here (Dart/pigeon name); the adapter exposes it as
//   `downloadItem`.
// - Enum values cross as their Dart names in plain strings (`MissingKind`, `MineKind`, …); the
//   adapter checks them.
// - Board PCM crosses as ONE base64 string per call: 16-bit little-endian mono samples (a board
//   packet is ≤ 1 KB, about 50 calls/s). RN 0.88's Java codegen also maps `ArrayBuffer`
//   parameters (com.facebook.react.bridge.ArrayBuffer); per the plan's track note, T4 measures
//   the base64 cost and may propose that switch as a contract change.
// - Failures reject the promise with `code` = an `EngineErrorCode` name.
// - Events use codegen `EventEmitter<T>` (RN ≥ 0.76): Kotlin calls `emitOnMine(…)` etc.
import {TurboModuleRegistry} from 'react-native';
import type {CodegenTypes, EventSubscription, TurboModule} from 'react-native';
import {Capabilities} from '../core/model';
import {
  AudioRoute,
  AudioSessionKind,
  AudioSessionMsg,
  DownloadMsg,
  EngineError,
  EngineErrorCode,
  MineKind,
  MissingKind,
  MissingMsg,
  PairMsg,
  TypedEmitter,
  Unsubscribe,
  VoiceEngine,
  VoiceEngineEvents,
  audioRoutes,
  audioSessionKinds,
  capabilitiesFromMsg,
  mineKinds,
  missingKinds,
  pcm16leBase64,
} from './VoiceEngine';

// --- wire types (codegen needs them in this file) -----------------------------------------

export type NativeRecognizerEntryMsg = {
  language: string;
  /** `RecognizerKind` names. */
  kinds: string[];
};

export type NativeCapabilitiesMsg = {
  recognizers: NativeRecognizerEntryMsg[];
  translatable: string[];
  vietnameseVoice: boolean;
};

export type NativeMissingMsg = {
  /** `MissingKind` name. */
  kind: string;
  language: string;
  from?: string | null;
  to?: string | null;
};

export type NativePairMsg = {
  home: string;
  other: string;
  generation: CodegenTypes.Int32;
};

export type NativeMineMsg = {
  /** `MineKind` name: "partial" | "finalText". */
  kind: string;
  text: string;
  startMs: CodegenTypes.Double;
  endMs: CodegenTypes.Double;
};

export type NativeTheirsMsg = {
  text: string;
  confidence?: CodegenTypes.Double | null;
  generation: CodegenTypes.Int32;
};

export type NativeAudioSessionMsg = {
  /** `AudioSessionKind` name. */
  kind: string;
  /** `AudioRoute` name. */
  route?: string | null;
};

export type NativeDownloadMsg = {
  item: NativeMissingMsg;
  progress: CodegenTypes.Double;
  done: boolean;
  error?: string | null;
};

export interface Spec extends TurboModule {
  capabilities(home: string): Promise<NativeCapabilitiesMsg>;
  missing(pair: NativePairMsg): Promise<NativeMissingMsg[]>;
  download(item: NativeMissingMsg): Promise<void>;
  start(pair: NativePairMsg, recognizerX: string, hints: string[]): Promise<void>;
  stop(): Promise<void>;
  micOn(on: boolean): Promise<void>;
  /** `pcm16leBase64`: base64 of 16-bit little-endian mono samples. */
  feedTheirAudio(pcm16leBase64: string, sampleRate: CodegenTypes.Int32): Promise<void>;
  translate(text: string, from: string, to: string): Promise<string>;
  speak(text: string, id: CodegenTypes.Int32): Promise<void>;
  stopSpeaking(): Promise<void>;
  setHints(hints: string[]): Promise<void>;
  openTtsSettings(): Promise<void>;

  readonly onMine: CodegenTypes.EventEmitter<NativeMineMsg>;
  readonly onTheirs: CodegenTypes.EventEmitter<NativeTheirsMsg>;
  readonly onGate: CodegenTypes.EventEmitter<boolean>;
  readonly onTtsStart: CodegenTypes.EventEmitter<CodegenTypes.Int32>;
  readonly onTtsEnd: CodegenTypes.EventEmitter<CodegenTypes.Int32>;
  readonly onAudioSession: CodegenTypes.EventEmitter<NativeAudioSessionMsg>;
  readonly onDownload: CodegenTypes.EventEmitter<NativeDownloadMsg>;
}

/** Name the Kotlin module registers under. */
export const voiceEngineModuleName = 'VoiceEngine';

/** The native module; throws when it is not linked (looked up on call, not at import). */
export function getNativeVoiceEngine(): Spec {
  return TurboModuleRegistry.getEnforcing<Spec>('VoiceEngine');
}

// --- adapter -----------------------------------------------------------------------------

function oneOf<T extends string>(values: readonly T[], value: unknown, what: string): T {
  if (typeof value === 'string' && (values as readonly string[]).includes(value)) {
    return value as T;
  }
  throw new Error(`unknown ${what} "${String(value)}"`);
}

function missingFromWire(m: NativeMissingMsg): MissingMsg {
  return {
    kind: oneOf<MissingKind>(missingKinds, m.kind, 'MissingKind'),
    language: m.language,
    from: m.from ?? null,
    to: m.to ?? null,
  };
}

function missingToWire(m: MissingMsg): NativeMissingMsg {
  return {kind: m.kind, language: m.language, from: m.from ?? null, to: m.to ?? null};
}

/** `VoiceEngine` over the TurboModule: wire conversion, typed errors, typed events. */
export class NativeVoiceEngineAdapter implements VoiceEngine {
  private readonly events = new TypedEmitter<VoiceEngineEvents>();
  private readonly subscriptions: EventSubscription[];

  constructor(private readonly native: Spec = getNativeVoiceEngine()) {
    this.subscriptions = [
      native.onMine(m =>
        this.forward('mine', () => ({
          kind: oneOf<MineKind>(mineKinds, m.kind, 'MineKind'),
          text: m.text,
          startMs: m.startMs,
          endMs: m.endMs,
        })),
      ),
      native.onTheirs(m =>
        this.forward('theirs', () => ({
          text: m.text,
          confidence: m.confidence ?? null,
          generation: m.generation,
        })),
      ),
      native.onGate(open => this.forward('gate', () => open)),
      native.onTtsStart(id => this.forward('ttsStart', () => id)),
      native.onTtsEnd(id => this.forward('ttsEnd', () => id)),
      native.onAudioSession(m =>
        this.forward('audioSession', (): AudioSessionMsg => ({
          kind: oneOf<AudioSessionKind>(audioSessionKinds, m.kind, 'AudioSessionKind'),
          route: m.route == null ? null : oneOf<AudioRoute>(audioRoutes, m.route, 'AudioRoute'),
        })),
      ),
      native.onDownload(m =>
        this.forward('download', (): DownloadMsg => ({
          item: missingFromWire(m.item),
          progress: m.progress,
          done: m.done,
          error: m.error ?? null,
        })),
      ),
    ];
  }

  /** Converts and emits; a malformed native event is dropped with a warning, never thrown into native code. */
  private forward<K extends keyof VoiceEngineEvents>(
    event: K,
    convert: () => VoiceEngineEvents[K],
  ): void {
    let payload: VoiceEngineEvents[K];
    try {
      payload = convert();
    } catch (e) {
      console.warn(`VoiceEngine: dropped ${event} event: ${(e as Error).message}`);
      return;
    }
    this.events.emit(event, payload);
  }

  /** Maps a rejection whose `code` names an `EngineError` (else `fallback`); rethrows anything else. */
  private async call<T>(run: () => Promise<T>, fallback?: EngineErrorCode): Promise<T> {
    try {
      return await run();
    } catch (e) {
      const message = e instanceof Error ? e.message : undefined;
      const mapped =
        EngineError.fromCode((e as {code?: unknown} | null)?.code, message) ??
        (fallback ? new EngineError(fallback, message) : null);
      throw mapped ?? e;
    }
  }

  on<K extends keyof VoiceEngineEvents>(
    event: K,
    handler: (payload: VoiceEngineEvents[K]) => void,
  ): Unsubscribe {
    return this.events.on(event, handler);
  }

  /** Removes the native subscriptions and every handler. */
  dispose(): void {
    this.subscriptions.forEach(s => s.remove());
    this.events.removeAll();
  }

  async capabilities(home: string): Promise<Capabilities> {
    return capabilitiesFromMsg(await this.call(() => this.native.capabilities(home)));
  }

  async missing(pair: PairMsg): Promise<MissingMsg[]> {
    const list = await this.call(() => this.native.missing({...pair}));
    return list.map(missingFromWire);
  }

  downloadItem(item: MissingMsg): Promise<void> {
    return this.call(() => this.native.download(missingToWire(item)), 'downloadFailed');
  }

  start(pair: PairMsg, recognizerX: string, hints: readonly string[]): Promise<void> {
    return this.call(() => this.native.start({...pair}, recognizerX, [...hints]));
  }

  stop(): Promise<void> {
    return this.call(() => this.native.stop());
  }

  micOn(on: boolean): Promise<void> {
    return this.call(() => this.native.micOn(on));
  }

  feedTheirAudio(pcm: Int16Array, sampleRate: number): Promise<void> {
    return this.call(() => this.native.feedTheirAudio(pcm16leBase64(pcm), sampleRate));
  }

  translate(text: string, from: string, to: string): Promise<string> {
    return this.call(() => this.native.translate(text, from, to), 'translateFailed');
  }

  speak(text: string, id: number): Promise<void> {
    return this.call(() => this.native.speak(text, id));
  }

  stopSpeaking(): Promise<void> {
    return this.call(() => this.native.stopSpeaking());
  }

  setHints(hints: readonly string[]): Promise<void> {
    return this.call(() => this.native.setHints([...hints]));
  }

  openTtsSettings(): Promise<void> {
    return this.call(() => this.native.openTtsSettings());
  }
}
