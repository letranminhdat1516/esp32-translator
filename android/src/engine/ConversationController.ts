// The Android app's conversation: drives ARCHITECTURE.md §2 steps 1-8 against the `VoiceEngine` and
// `BoardLink` interfaces, owns the session machine (§3), handles the failures of §6, and publishes
// a `UiState` for the screens (`subscribe`, `getState`). It is also the screens' `UiIntents`.
//
// Behavioural spec: .superpowers/sdd/PLAN/phase2.md "Task P2.1" (written for the Flutter app) and
// the Swift `ConversationEngine` it replaces (their phrases strictly in order, the echo hold, the
// confidence gate shown dimmed, the board showing the current turn only).
import {ADPCMDecoder} from '../board/adpcm';
import type {BoardControl, BoardLink, BoardState} from '../board/BoardLink';
import {graphemes, timeText} from '../board/protocol';
import {BoardGlyphSets} from '../core/boardGlyphs';
import {BoardText} from '../core/boardText';
import {ConversationActivity, type ActivityEvent, type ActivityTransition} from '../core/conversationActivity';
import {GlossaryError, type GlossaryStore, type KeyValueStore} from '../core/glossary';
import {LanguageCatalog, type Platform} from '../core/languageCatalog';
import type {Capabilities, LanguagePack, RecognizerKind, Term} from '../core/model';
import {RuleEngine} from '../core/ruleEngine';
import {SubtitleTranslator} from '../core/subtitleTranslator';
import {TextPipeline} from '../core/textPipeline';
import {TurnAssembler} from '../core/turnAssembler';
import {t} from '../ui/copy';
import {
  GlossaryValidationError,
  emptyUiState,
  glossaryMessageFor,
  type UiIntents,
  type UiLine,
  type UiPhase,
  type UiState,
} from '../ui/uiState';
import {Session, SessionEvent, SessionState, advance, sessionStateEquals} from './sessionMachine';
import {
  EngineError,
  type AudioSessionMsg,
  type DownloadMsg,
  type MineMsg,
  type MissingMsg,
  type PairMsg,
  type TheirsMsg,
  type Unsubscribe,
  type VoiceEngine,
} from './VoiceEngine';

/** Where the picked language is kept (AsyncStorage in the app: src/ui/pickStorage.ts). */
export interface PickStore {
  load(): Promise<string | null>;
  save(code: string): Promise<void>;
}

/** An in-memory `PickStore` (tests). */
export class MemoryPickStore implements PickStore {
  constructor(public code: string | null = null) {}
  async load(): Promise<string | null> {
    return this.code;
  }
  async save(code: string): Promise<void> {
    this.code = code;
  }
}

/** Android runtime permissions, asked when first needed (ARCHITECTURE.md §7). */
export interface PermissionGate {
  /** Microphone (and notifications on API 33+) before a session starts; false: microphone refused. */
  session(): Promise<boolean>;
  /** Bluetooth scan/connect (location on Android 10-11), asked at launch; false: refused. */
  board(): Promise<boolean>;
}

export const allGranted: PermissionGate = {
  session: async () => true,
  board: async () => true,
};

export interface ControllerTimers {
  setInterval(work: () => void, ms: number): unknown;
  clearInterval(handle: unknown): void;
}

/** The global timers, looked up at call time (so Jest's fake timers apply). */
const globalTimers: ControllerTimers = {
  setInterval: (work, ms) => setInterval(work, ms),
  clearInterval: handle => clearInterval(handle as ReturnType<typeof setInterval>),
};

export interface ConversationControllerOptions {
  readonly engine: VoiceEngine;
  readonly board: BoardLink;
  /** The bundled language packs, including the home pack (`vi`). */
  readonly packs: readonly LanguagePack[];
  readonly pickStore: PickStore;
  /** Opens the user's glossary; absent: no glossary (tests). */
  readonly openGlossary?: () => Promise<GlossaryStore>;
  /** Keeps the online-recognizer consent (key `onlineAllowed`); absent: in memory only. */
  readonly settings?: KeyValueStore;
  readonly permissions?: PermissionGate;
  /** The board's CJK/Hangul/Thai glyph lists (default `BoardGlyphSets.shared`, loaded at startup). */
  readonly glyphs?: BoardGlyphSets;
  readonly platform?: Platform;
  /** Epoch milliseconds. */
  readonly now?: () => number;
  readonly timers?: ControllerTimers;
  /** Interval of the ConversationActivity idle check (Swift: 5 s). */
  readonly tickMs?: number;
  readonly activity?: ConversationActivity;
  /** Their phrases are dropped this long after the wearer spoke (the board mic hears the wearer). */
  readonly echoHoldMs?: number;
  readonly log?: (message: string) => void;
}

/** Session failure reasons the controller itself gives (the machine gives 'recognizer stopped'). */
export const FailureReason = {
  microphone: 'microphone permission',
  noRecognizer: 'no recognizer',
  recognizerStopped: 'recognizer stopped',
} as const;

const homeCode = LanguageCatalog.homeCode;
const boardSampleRate = 16000;
const maxLines = 50;
const consentKey = 'onlineAllowed';

type Listener = (state: UiState) => void;

export class ConversationController implements UiIntents {
  private readonly engine: VoiceEngine;
  private readonly board: BoardLink;
  private readonly packs: readonly LanguagePack[];
  private readonly home: LanguagePack;
  private readonly pickStore: PickStore;
  private readonly settings: KeyValueStore | null;
  private readonly openGlossary: (() => Promise<GlossaryStore>) | null;
  private readonly permissions: PermissionGate;
  private readonly boardText: BoardText;
  private readonly platform: Platform;
  private readonly now: () => number;
  private readonly timers: ControllerTimers;
  private readonly tickMs: number;
  private readonly activity: ConversationActivity;
  private readonly echoHoldMs: number;
  private readonly logLine: (message: string) => void;

  private ui: UiState;
  private readonly listeners = new Set<Listener>();
  private readonly unsubs: Unsubscribe[] = [];
  private tickHandle: unknown = null;
  private disposed = false;
  private started = false;

  private session: Session = {state: {type: 'loading'}, generation: 0};
  /** Bumped on every state change: an effect whose state is gone stops. */
  private seq = 0;
  private caps: Capabilities = {recognizers: {}, translatable: new Set(), vietnameseVoice: true};
  private catalog: LanguageCatalog;
  private consent = new Set<string>();
  private glossary: GlossaryStore | null = null;
  private glossaryTerms: readonly Term[] = [];

  /** The pair being prepared or running, with its text pipeline. */
  private pair: {readonly pack: LanguagePack; readonly generation: number; pipeline: TextPipeline} | null =
    null;
  /** The last missing list (a failed download returns to needsDownload without it). */
  private lastMissing: readonly MissingMsg[] = [];
  /** The engine runs a session (start resolved, no stop since). */
  private engineRunning = false;
  private runningKind: RecognizerKind | null = null;
  private runningPair: PairMsg | null = null;
  private deathReported = false;

  private readonly decoder = new ADPCMDecoder();
  private theirChain: Promise<void> = Promise.resolve();
  private nextSpeechId = 1;
  private readonly turns: TurnAssembler;
  private subtitles: SubtitleTranslator | null = null;
  private myLastSpeechMs = -Infinity;

  constructor(options: ConversationControllerOptions) {
    this.engine = options.engine;
    this.board = options.board;
    this.packs = options.packs;
    const home = options.packs.find(p => p.code === homeCode);
    if (!home) {
      throw new Error(`no "${homeCode}" language pack`);
    }
    this.home = home;
    this.pickStore = options.pickStore;
    this.settings = options.settings ?? null;
    this.openGlossary = options.openGlossary ?? null;
    this.permissions = options.permissions ?? allGranted;
    this.boardText = new BoardText(options.glyphs ?? BoardGlyphSets.shared);
    this.platform = options.platform ?? 'android';
    this.now = options.now ?? (() => Date.now());
    this.timers = options.timers ?? globalTimers;
    this.tickMs = options.tickMs ?? 5000;
    this.activity = options.activity ?? new ConversationActivity();
    this.echoHoldMs = options.echoHoldMs ?? 1000;
    this.logLine = options.log ?? (m => console.log(`ConversationController: ${m}`));
    const homeRules = RuleEngine.forPack(home);
    this.turns = new TurnAssembler({fixLoanwords: s => homeRules.fixRecognition(s)});
    this.catalog = this.makeCatalog();
    this.ui = {
      ...emptyUiState,
      phase: 'needsDownload',
      session: this.session.state,
      board: this.board.currentState,
      languageNames: this.languageNames(),
    };
  }

  // --- the store -------------------------------------------------------------------------

  getState = (): UiState => this.ui;

  subscribe = (listener: Listener): Unsubscribe => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** The session (state + generation of "their" side), for tests and diagnostics. */
  get currentSession(): Session {
    return this.session;
  }

  private patch(p: Partial<UiState>): void {
    if (this.disposed) {
      return;
    }
    this.ui = {...this.ui, ...p};
    for (const l of [...this.listeners]) {
      try {
        l(this.ui);
      } catch (e) {
        this.log(`a UI listener threw: ${String(e)}`);
      }
    }
  }

  private log(message: string): void {
    this.logLine(message);
  }

  // --- lifecycle -------------------------------------------------------------------------

  /** Step 1: subscribes, reads the glossary, consent, capabilities and the saved pick. Once. */
  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    const e = this.engine;
    this.unsubs.push(
      e.on('theirs', m => this.onTheirs(m)),
      e.on('mine', m => this.onMine(m)),
      e.on('gate', open => this.activityEvent(open ? 'gateOpen' : 'gateClosed')),
      e.on('ttsStart', () => this.activityEvent('ttsStart')),
      e.on('ttsEnd', () => this.activityEvent('ttsEnd')),
      e.on('audioSession', m => this.onAudioSession(m)),
      e.on('download', m => this.onDownloadProgress(m)),
      this.board.on('state', s => this.onBoardState(s)),
      this.board.on('audio', p => this.onBoardAudio(p)),
      this.board.on('control', c => this.onBoardControl(c)),
    );
    this.tickHandle = this.timers.setInterval(() => this.activityEvent('tick'), this.tickMs);
    // A link that became ready before we subscribed gets its clock now (the label follows on start).
    this.onBoardState(this.board.currentState);

    this.permissions.board().then(
      granted => {
        if (!granted) {
          this.log('Bluetooth permission refused: no board');
        }
      },
      err => this.log(`Bluetooth permission: ${String(err)}`),
    );

    await this.loadGlossary();
    await this.loadConsent();
    await this.refreshCapabilities();
    let saved: string | null = null;
    try {
      saved = await this.pickStore.load();
    } catch (err) {
      this.log(`reading the pick: ${String(err)}`);
    }
    const offered = new Set(this.catalog.offered.map(p => p.code));
    if (saved === null && offered.has('en')) {
      saved = 'en'; // the default pick (ARCHITECTURE.md §2.1)
    }
    this.dispatch({type: 'catalogReady', saved, offered});
  }

  /** Unsubscribes everything and stops the engine. */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.unsubs.splice(0).forEach(u => u());
    if (this.tickHandle !== null) {
      this.timers.clearInterval(this.tickHandle);
      this.tickHandle = null;
    }
    this.glossary?.dispose();
    this.disposed = true;
    this.seq++;
    if (this.engineRunning) {
      this.engineRunning = false;
      this.engine.stop().catch(err => this.log(`stop: ${String(err)}`));
    }
  }

  private async loadGlossary(): Promise<void> {
    if (!this.openGlossary) {
      return;
    }
    try {
      const store = await this.openGlossary();
      this.glossary = store;
      if (store.recoveredFromCorruption) {
        this.log('glossary data was unreadable: set aside, starting empty');
      }
      this.glossaryTerms = store.terms;
      this.unsubs.push(store.onChange(terms => this.onGlossaryChanged(terms)));
      this.patch({glossaryTerms: store.terms});
    } catch (err) {
      this.log(`opening the glossary: ${String(err)}`);
    }
  }

  private async loadConsent(): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      const raw = await this.settings.getItem(consentKey);
      const list: unknown = raw === null ? [] : JSON.parse(raw);
      if (Array.isArray(list)) {
        this.consent = new Set(list.filter((c): c is string => typeof c === 'string'));
      }
    } catch (err) {
      this.log(`reading the online consent: ${String(err)}`);
    }
  }

  private async refreshCapabilities(): Promise<void> {
    try {
      this.caps = await this.engine.capabilities(homeCode);
    } catch (err) {
      this.log(`capabilities: ${String(err)}`);
    }
    this.catalog = this.makeCatalog();
    this.publishCatalog();
  }

  private makeCatalog(consent: ReadonlySet<string> = this.consent): LanguageCatalog {
    return new LanguageCatalog({
      packs: this.packs,
      caps: this.caps,
      platform: this.platform,
      onlineConsent: consent,
    });
  }

  private publishCatalog(): void {
    const offered = this.catalog.offered;
    const onlineCodes = offered
      .filter(p => this.catalog.chain(p.code)[0] === 'osOnline')
      .map(p => p.code);
    const offeredCodes = new Set(offered.map(p => p.code));
    const everyone = this.makeCatalog(new Set(this.packs.map(p => p.code)));
    const onlineCandidates = everyone.offered.filter(p => !offeredCodes.has(p.code));
    this.patch({
      offeredPacks: offered,
      onlineCodes,
      onlineCandidates,
      onlineAllowed: [...this.consent],
      ttsVoiceMissing: this.ui.ttsVoiceMissing || !this.caps.vietnameseVoice,
    });
  }

  private languageNames(): Record<string, string> {
    const names: Record<string, string> = {};
    for (const p of this.packs) {
      names[p.code] = p.label;
    }
    names[homeCode] = t('header.home');
    return names;
  }

  // --- the session machine ------------------------------------------------------------------

  private dispatch(e: SessionEvent): boolean {
    if (this.disposed) {
      return false;
    }
    const before = this.session.state;
    this.session = advance(this.session, e);
    if (sessionStateEquals(before, this.session.state)) {
      return false;
    }
    this.seq++;
    this.publishSession();
    this.enter(this.session.state, this.seq);
    return true;
  }

  private publishSession(): void {
    const s = this.session.state;
    let phase: UiPhase = 'needsDownload';
    let message = '';
    switch (s.type) {
      case 'preparing':
        phase = 'preparing';
        message = t('status.preparing');
        break;
      case 'running':
        phase = 'running';
        break;
      case 'failed':
        phase = 'failed';
        message = this.failureText(s.reason);
        break;
      default:
        break;
    }
    const code = this.codeOf(s);
    const pack = code === null ? null : this.pack(code);
    this.patch({
      phase,
      message,
      session: s,
      currentCode: code,
      languageLabel: pack?.label ?? '',
      onlineRecognizer: s.type === 'running' && this.runningKind === 'osOnline',
      downloadProgress: s.type === 'downloading' ? this.ui.downloadProgress : null,
    });
  }

  private failureText(reason: string): string {
    switch (reason) {
      case FailureReason.recognizerStopped:
        return t('failed.recognizerStopped');
      case FailureReason.microphone:
        return t('permission.microphone');
      case FailureReason.noRecognizer:
        return t('failed.noRecognizer');
      default:
        return reason;
    }
  }

  private codeOf(s: SessionState): string | null {
    switch (s.type) {
      case 'loading':
      case 'choosing':
        return null;
      case 'switching':
        return s.to;
      default:
        return s.code;
    }
  }

  private pack(code: string): LanguagePack | null {
    return this.packs.find(p => p.code === code) ?? null;
  }

  /** Runs the work of a newly entered state; `seq` tells whether the state is still current. */
  private enter(s: SessionState, seq: number): void {
    const work = (() => {
      switch (s.type) {
        case 'checking':
          return this.check(s.code, seq);
        case 'switching':
          return this.switchTo(s.to, seq);
        case 'downloading':
          return this.download(s.code, seq);
        case 'preparing':
          return this.prepare(s.code, s.restarts, seq);
        case 'running':
          return this.onRunning(s.code);
        default:
          return Promise.resolve();
      }
    })();
    work.catch(err => this.log(`${s.type}: ${String(err)}`));
  }

  private current(seq: number): boolean {
    return !this.disposed && seq === this.seq;
  }

  private pairMsg(code: string): PairMsg {
    return {home: homeCode, other: code, generation: this.session.generation};
  }

  /** Builds the text pipeline of `code` for the current generation. */
  private usePair(code: string): void {
    const pack = this.pack(code);
    if (!pack) {
      this.pair = null;
      return;
    }
    if (this.pair?.pack.code === code && this.pair.generation === this.session.generation) {
      return;
    }
    this.pair = {pack, generation: this.session.generation, pipeline: this.makePipeline(pack)};
    this.subtitles = this.makeSubtitles();
  }

  private makePipeline(pack: LanguagePack): TextPipeline {
    return new TextPipeline({home: this.home, other: pack, glossary: this.glossaryTerms});
  }

  private hints(pack: LanguagePack | null): string[] {
    const all = [
      ...this.glossaryTerms.flatMap(term => [term.text, ...term.variants]),
      ...(pack?.hints ?? []),
      ...this.home.hints,
    ];
    return [...new Set(all)];
  }

  private async check(code: string, seq: number): Promise<void> {
    this.usePair(code);
    const missing = await this.missingFor(code);
    if (this.current(seq)) {
      this.dispatch({type: 'checked', missing});
    }
  }

  /** §2.7: the old "their" side is torn down; nothing of the old generation is spoken. */
  private async switchTo(code: string, seq: number): Promise<void> {
    this.usePair(code);
    try {
      await this.engine.stopSpeaking();
    } catch (err) {
      this.log(`stopSpeaking: ${String(err)}`);
    }
    if (!this.current(seq)) {
      return;
    }
    const missing = await this.missingFor(code);
    if (this.current(seq)) {
      this.dispatch({type: 'checked', missing});
    }
  }

  /**
   * What `code` still needs. The Vietnamese voice is not downloadable here (the user installs it in
   * the system settings): it raises the banner instead, and the text is still shown (§6).
   */
  private async missingFor(code: string): Promise<MissingMsg[]> {
    let all: MissingMsg[];
    try {
      all = await this.engine.missing(this.pairMsg(code));
    } catch (err) {
      this.log(`missing(${code}): ${String(err)}`);
      all = [];
    }
    const voiceMissing = all.some(m => m.kind === 'ttsVoice');
    const missing = all.filter(m => m.kind !== 'ttsVoice');
    this.patch({ttsVoiceMissing: voiceMissing || !this.caps.vietnameseVoice});
    if (missing.length > 0) {
      this.lastMissing = missing;
    }
    return missing;
  }

  private async download(code: string, seq: number): Promise<void> {
    let items = this.lastMissing;
    if (items.length === 0) {
      items = await this.missingFor(code);
    }
    this.downloadPlan = {items, index: 0};
    this.patch({downloadProgress: items.length === 0 ? null : 0});
    try {
      for (let i = 0; i < items.length; i++) {
        this.downloadPlan = {items, index: i};
        await this.engine.downloadItem(items[i]);
        if (!this.current(seq)) {
          return;
        }
      }
    } catch (err) {
      this.downloadPlan = null;
      if (this.current(seq)) {
        this.dispatch({type: 'downloadFailed', error: errorText(err)});
      }
      return;
    }
    this.downloadPlan = null;
    this.lastMissing = [];
    await this.refreshCapabilities();
    if (this.current(seq)) {
      this.dispatch({type: 'downloadDone'});
    }
  }

  private downloadPlan: {items: readonly MissingMsg[]; index: number} | null = null;

  private onDownloadProgress(m: DownloadMsg): void {
    const plan = this.downloadPlan;
    if (!plan || this.session.state.type !== 'downloading' || plan.items.length === 0) {
      return;
    }
    const p = Math.max(0, Math.min(1, m.progress));
    this.patch({downloadProgress: (plan.index + (m.done ? 1 : p)) / plan.items.length});
  }

  /** §2.4: permissions, then the engine with the catalog's recognizer chain (best first). */
  private async prepare(code: string, restarts: number, seq: number): Promise<void> {
    this.usePair(code);
    let granted: boolean;
    try {
      granted = await this.permissions.session();
    } catch (err) {
      this.log(`permissions: ${String(err)}`);
      granted = false;
    }
    if (!this.current(seq)) {
      return;
    }
    if (!granted) {
      this.dispatch({type: 'startFailed', reason: FailureReason.microphone});
      return;
    }
    const chain = this.catalog.chain(code);
    if (chain.length === 0) {
      this.dispatch({type: 'startFailed', reason: FailureReason.noRecognizer});
      return;
    }
    const pair = this.pairMsg(code);
    const same = this.runningPair;
    if (
      this.engineRunning &&
      same !== null &&
      same.other === pair.other &&
      same.generation === pair.generation
    ) {
      // A restart (dead recognizer, or Retry after it failed): the engine's start is idempotent
      // for the running pair, so it needs a stop first.
      this.log(`restart ${code} (restarts ${restarts})`);
      this.engineRunning = false;
      try {
        await this.engine.stop();
      } catch (err) {
        this.log(`stop before the restart: ${String(err)}`);
      }
    }
    const hints = this.hints(this.pack(code));
    let failure: unknown = null;
    for (const kind of chain) {
      try {
        await this.engine.start(pair, kind, hints);
        this.engineRunning = true;
        this.runningKind = kind;
        this.runningPair = pair;
        failure = null;
        break;
      } catch (err) {
        this.log(`start ${code} with ${kind}: ${String(err)}`);
        failure = err;
      }
    }
    if (!this.current(seq)) {
      return;
    }
    if (failure !== null) {
      this.dispatch({type: 'startFailed', reason: errorText(failure)});
      return;
    }
    this.dispatch({type: 'started'});
  }

  private async onRunning(code: string): Promise<void> {
    this.deathReported = false;
    this.patch({onlineRecognizer: this.runningKind === 'osOnline'});
    if (this.activity.isActive) {
      this.setMic(true);
    }
    await this.sendLabel(code);
  }

  // --- the board ---------------------------------------------------------------------------

  /** The label in the pack's own script when the board can draw it, else the Latin one. */
  private labelFor(pack: LanguagePack): string {
    const shown = this.boardText.encode(pack.label, this.board.info.fontSets);
    return shown === pack.label.normalize('NFC') ? pack.label : pack.labelLatin;
  }

  private async sendLabel(code: string): Promise<void> {
    const pack = this.pack(code);
    if (!pack) {
      return;
    }
    try {
      await this.board.sendText(this.labelFor(pack), 'label');
    } catch (err) {
      this.log(`label: ${String(err)}`);
    }
  }

  private onBoardState(s: BoardState): void {
    this.decoder.reset();
    this.patch({board: s});
    if (s === 'ready') {
      this.sendClockAndLabel().catch(err => this.log(`clock/label: ${String(err)}`));
    }
  }

  /** On every `ready` (first connect and reconnects): the clock, then the label (Review Focus 1). */
  private async sendClockAndLabel(): Promise<void> {
    await this.board.sendText(timeText(new Date(this.now())), 'time');
    const code = this.ui.currentCode;
    if (code !== null) {
      await this.sendLabel(code);
    }
  }

  private onBoardControl(c: BoardControl): void {
    if (c.type === 'micChanged') {
      this.patch({boardMicOn: c.on});
      if (c.on) {
        this.activityEvent('userStart');
      }
    }
  }

  /** §2.5: board ADPCM → PCM → their recognizer. */
  private onBoardAudio(packet: Uint8Array): void {
    const pcm = this.decoder.decode(packet);
    if (pcm.length === 0) {
      return;
    }
    this.activityEvent('boardAudio');
    const s = this.session.state;
    if (s.type !== 'running' || !this.engineRunning) {
      return;
    }
    const generation = this.session.generation;
    this.engine.feedTheirAudio(pcm, boardSampleRate).catch(err => {
      // The engine rejects a feed with notReady when their recognizer is gone (§6).
      if (
        err instanceof EngineError &&
        err.code === 'notReady' &&
        !this.deathReported &&
        this.session.state.type === 'running' &&
        this.session.generation === generation
      ) {
        this.deathReported = true;
        this.log('their recognizer stopped');
        this.dispatch({type: 'recognizerDied'});
      }
    });
  }

  // --- them → you ----------------------------------------------------------------------------

  private onTheirs(m: TheirsMsg): void {
    const s = this.session.state;
    if (s.type !== 'running' || m.generation !== this.session.generation || !this.pair) {
      return; // late result of an old generation (§2.7)
    }
    const now = this.now();
    if (this.ui.myPartial !== '' || now - this.myLastSpeechMs < this.echoHoldMs) {
      return; // the board mic heard the wearer
    }
    const text = m.text.trim();
    if (graphemes(text).length <= 1) {
      return;
    }
    const min = this.pair.pack.minConfidence;
    if (m.confidence !== null && min !== null && m.confidence < min) {
      // Speaking a wrong translation is worse than saying nothing: shown dimmed only.
      this.addTheirLine({id: String(this.nextSpeechId++), source: text, target: t('line.unclear'), unclear: true, at: now});
      return;
    }
    const generation = m.generation;
    this.theirChain = this.theirChain
      .then(() => this.translateAndSpeak(text, generation))
      .catch(err => this.log(`their phrase: ${String(err)}`));
  }

  /** One phrase, strictly after the previous one (one queue, as the Swift app). */
  private async translateAndSpeak(text: string, generation: number): Promise<void> {
    const pair = this.pair;
    if (!pair || generation !== this.session.generation || pair.generation !== generation) {
      return;
    }
    const other = pair.pack.code;
    let vietnamese: string;
    try {
      vietnamese = await pair.pipeline.translate(text, 'theirs', s => this.engine.translate(s, other, homeCode));
    } catch (err) {
      this.log(`translate ${other}→${homeCode} failed, phrase skipped: ${String(err)}`);
      return;
    }
    // Review Focus 2: a switch while this was translating: nothing of the old pair is spoken.
    if (generation !== this.session.generation || vietnamese.trim() === '') {
      return;
    }
    const id = this.nextSpeechId++;
    this.addTheirLine({id: String(id), source: text, target: vietnamese, at: this.now()});
    try {
      await this.engine.speak(vietnamese, id);
    } catch (err) {
      this.log(`speak: ${String(err)}`);
    }
  }

  private addTheirLine(line: UiLine): void {
    this.patch({theirLines: [...this.ui.theirLines, line].slice(-maxLines)});
  }

  // --- you → them ----------------------------------------------------------------------------

  /** The subtitle translator of one pair; results of a replaced one are dropped. */
  private makeSubtitles(): SubtitleTranslator {
    const subtitles: SubtitleTranslator = new SubtitleTranslator({
      translate: async text => {
        const pair = this.pair;
        if (!pair || this.subtitles !== subtitles) {
          return text;
        }
        try {
          return await pair.pipeline.translate(text, 'mine', s =>
            this.engine.translate(s, homeCode, pair.pack.code),
          );
        } catch (err) {
          // §6: the subtitle keeps the source text.
          this.log(`translate ${homeCode}→${pair.pack.code} failed, source kept: ${String(err)}`);
          return text;
        }
      },
      onResult: (turn, translation) => {
        if (this.subtitles === subtitles) {
          this.showSubtitle(turn, translation);
        }
      },
      log: m => this.log(`subtitles: ${m}`),
    });
    return subtitles;
  }

  private onMine(m: MineMsg): void {
    const now = this.now();
    const change = this.turns.handle(
      m.kind === 'partial' ? {kind: 'partial', text: m.text} : {kind: 'final', text: m.text},
      now,
    );
    const turn = this.turns.turn;
    if (change === null || turn === null) {
      return;
    }
    if (turn.partial !== '' || change.finalText !== null) {
      this.myLastSpeechMs = now;
    }
    const id = String(turn.id);
    const lines = [...this.ui.myLines];
    const last = lines[lines.length - 1];
    if (last === undefined || last.id !== id) {
      lines.push({id, source: turn.text, target: '', at: now});
    } else if (last.source !== turn.text) {
      lines[lines.length - 1] = {...last, source: turn.text, at: now};
    }
    this.patch({myPartial: turn.partial, myLines: lines.slice(-maxLines)});
    const subtitles = this.subtitles;
    if (subtitles) {
      if (change.finalText !== null) {
        subtitles.addFinal(change.finalText, turn.id);
      }
      subtitles.setPartial(turn.partial, turn.id);
    }
  }

  private showSubtitle(turn: number, translation: string): void {
    const lines = [...this.ui.myLines];
    const index = lines.findIndex(l => l.id === String(turn));
    if (index < 0) {
      return;
    }
    lines[index] = {...lines[index], target: translation};
    this.patch({myLines: lines});
    // The board shows the current turn only; a late result for an earlier turn just fixes its line.
    if (index === lines.length - 1) {
      const shown = this.boardText.encode(translation, this.board.info.fontSets);
      this.board.sendText(shown, 'subtitle').catch(err => this.log(`subtitle: ${String(err)}`));
    }
  }

  // --- conversation on/off ---------------------------------------------------------------------

  private activityEvent(e: ActivityEvent): void {
    const transition = this.activity.handle(e, this.now());
    if (transition !== null) {
      this.applyActivity(transition);
    }
  }

  private applyActivity(transition: ActivityTransition): void {
    this.patch({listening: this.activity.isActive});
    this.setMic(transition === 'start');
  }

  /** The earbuds mic follows ConversationActivity; only a running engine is told. */
  private setMic(on: boolean): void {
    if (!this.engineRunning) {
      return;
    }
    this.engine.micOn(on).catch(err => {
      this.log(`micOn(${on}): ${String(err)}`);
      if (on) {
        this.activity.startFailed(this.now());
        this.patch({listening: false});
      }
    });
  }

  private onAudioSession(m: AudioSessionMsg): void {
    if (m.route) {
      this.patch({micRoute: m.route});
    }
    if (m.kind === 'interrupted') {
      this.activityEvent('stop');
    }
  }

  // --- glossary ---------------------------------------------------------------------------------

  /** §2.8: pipelines rebuilt, hints to the recognizers. */
  private onGlossaryChanged(terms: readonly Term[]): void {
    this.glossaryTerms = terms;
    if (this.pair) {
      this.pair.pipeline = this.makePipeline(this.pair.pack);
    }
    this.patch({glossaryTerms: terms});
    if (this.engineRunning) {
      this.engine
        .setHints(this.hints(this.pair?.pack ?? null))
        .catch(err => this.log(`setHints: ${String(err)}`));
    }
  }

  private async glossaryCall(run: (store: GlossaryStore) => Promise<unknown>): Promise<void> {
    const store = this.glossary;
    if (!store) {
      throw new Error('the glossary is not available');
    }
    try {
      await run(store);
    } catch (err) {
      const message = err instanceof GlossaryError ? glossaryMessageFor(err.name) : undefined;
      throw message === undefined ? err : new GlossaryValidationError(message);
    }
  }

  // --- UiIntents ----------------------------------------------------------------------------------

  toggleBoardMic = (): void => {
    const on = !this.ui.boardMicOn;
    this.patch({boardMicOn: on});
    this.board.setBoardMic(on).catch(err => this.log(`board mic: ${String(err)}`));
    if (on) {
      this.activityEvent('userStart');
    }
  };

  startListening = (): void => {
    this.activityEvent('userStart');
  };

  stopListening = (): void => {
    this.activityEvent('userStop');
  };

  clearHistory = (): void => {
    this.turns.reset();
    this.subtitles?.reset();
    this.patch({theirLines: [], myLines: [], theirPartial: '', myPartial: ''});
    this.board.sendText('', 'subtitle').catch(err => this.log(`clear subtitle: ${String(err)}`));
  };

  onDownload = (): void => {
    this.dispatch({type: 'downloadTapped'});
  };

  onRetry = (): void => {
    const s = this.session.state;
    this.dispatch(s.type === 'needsDownload' ? {type: 'downloadTapped'} : {type: 'retry'});
  };

  pickLanguage = (code: string): void => {
    if (this.dispatch({type: 'picked', code})) {
      this.pickStore.save(code).catch(err => this.log(`saving the pick: ${String(err)}`));
    }
  };

  setOnlineAllowed = (code: string, on: boolean): void => {
    const next = new Set(this.consent);
    if (on) {
      next.add(code);
    } else {
      next.delete(code);
    }
    this.consent = next;
    this.catalog = this.makeCatalog();
    this.publishCatalog();
    this.settings
      ?.setItem(consentKey, JSON.stringify([...next]))
      .catch(err => this.log(`saving the online consent: ${String(err)}`));
  };

  openTtsSettings = (): void => {
    this.engine.openTtsSettings().catch(err => this.log(`TTS settings: ${String(err)}`));
  };

  addTerm = (text: string): Promise<void> => this.glossaryCall(store => store.add({text}));

  updateTerm = (id: string, text: string): Promise<void> =>
    this.glossaryCall(store => {
      const old = store.terms.find(term => term.id === id);
      return store.update(id, {text, variants: old?.variants, fixed: old?.fixed});
    });

  deleteTerm = (id: string): Promise<void> => this.glossaryCall(store => store.remove(id));
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
