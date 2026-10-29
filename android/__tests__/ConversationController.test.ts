/* eslint-disable no-bitwise -- board packet bytes */
// P2.1: the conversation controller against FakeVoiceEngine + FakeBoardLink (ARCHITECTURE.md §2,
// §3, §6; PLAN.md Review Focus 1 and 2).
import {FakeBoardLink} from '../src/board/FakeBoardLink';
import {BoardGlyphSets} from '../src/core/boardGlyphs';
import {ConversationActivity} from '../src/core/conversationActivity';
import {GlossaryStore, MemoryKeyValueStore} from '../src/core/glossary';
import {FontSets, type Capabilities} from '../src/core/model';
import {bundledPacks} from '../src/core/sharedAssets';
import {
  ConversationController,
  MemoryPickStore,
  type ConversationControllerOptions,
  type PermissionGate,
} from '../src/engine/ConversationController';
import {FakeVoiceEngine} from '../src/engine/FakeVoiceEngine';
import {EngineError, type MissingMsg} from '../src/engine/VoiceEngine';
import {t} from '../src/ui/copy';
import {GlossaryMessages, GlossaryValidationError} from '../src/ui/uiState';

/** Translates by tagging the target code (`vi:Hello`), unless a translation is scripted; can hold. */
class ScriptedEngine extends FakeVoiceEngine {
  private held: Array<() => void> = [];
  hold = false;

  async translate(text: string, from: string, to: string): Promise<string> {
    const out = await super.translate(text, from, to);
    if (this.hold) {
      await new Promise<void>(resolve => this.held.push(resolve));
    }
    return this.translations.has(text) ? out : `${to}:${text}`;
  }

  release(): void {
    this.hold = false;
    this.held.splice(0).forEach(r => r());
  }
}

const caps = (): Capabilities => ({
  recognizers: {en: ['whisper', 'osOnline'], fr: ['whisper'], ja: ['whisper']},
  translatable: new Set(['vi', 'en', 'fr', 'ja']),
  vietnameseVoice: true,
});

async function flush(): Promise<void> {
  for (let i = 0; i < 200; i++) {
    await Promise.resolve();
  }
}

let seq = 0;
/** One board audio packet: `[seq u16][predictor i16][index u8][data]`, 20 data bytes. */
function packet(): Uint8Array {
  const p = new Uint8Array(25);
  p[0] = seq & 0xff;
  p[1] = (seq >> 8) & 0xff;
  seq++;
  p.fill(0x31, 5);
  return p;
}

const controllers: ConversationController[] = [];

function setup(
  options: Partial<ConversationControllerOptions> & {pick?: MemoryPickStore; engine?: ScriptedEngine} = {},
) {
  const engine = options.engine ?? new ScriptedEngine(caps());
  const board = (options.board as FakeBoardLink | undefined) ?? new FakeBoardLink();
  const pick = options.pick ?? new MemoryPickStore();
  const clock = {now: 1_700_000_000_000};
  const logs: string[] = [];
  const c = new ConversationController({
    packs: bundledPacks(),
    glyphs: new BoardGlyphSets(),
    log: m => logs.push(m),
    ...options,
    engine,
    board,
    pickStore: pick,
    now: () => clock.now,
  });
  controllers.push(c);
  const advance = (ms: number) => {
    clock.now += ms;
  };
  return {engine, board, pick, c, clock, advance, logs};
}

/** Started and running `en` (the default pick). */
async function running(options: Parameters<typeof setup>[0] = {}) {
  const env = setup(options);
  await env.c.start();
  await flush();
  expect(env.c.currentSession.state.type).toBe('running');
  return env;
}

const subtitles = (board: FakeBoardLink) => board.sentTexts.filter(s => s.kind === 'subtitle');
const labels = (board: FakeBoardLink) => board.sentTexts.filter(s => s.kind === 'label').map(s => s.text);

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  controllers.splice(0).forEach(c => c.dispose());
  jest.useRealTimers();
});

describe('ConversationController', () => {
  it('runs a whole conversation both ways', async () => {
    const {engine, board, c, advance} = await running();
    expect(engine.capabilitiesCalls).toEqual(['vi']);
    expect(engine.starts).toHaveLength(1);
    expect(engine.starts[0].pair).toEqual({home: 'vi', other: 'en', generation: 0});
    expect(engine.starts[0].recognizerX).toBe('whisper');
    expect(c.getState().phase).toBe('running');
    expect(c.getState().currentCode).toBe('en');
    expect(c.getState().languageLabel).toBe('English');

    // The label goes at start (the link keeps it for later), then clock + label on ready.
    board.emitState('ready');
    await flush();
    expect(board.sentTexts.map(s => s.kind)).toEqual(['label', 'time', 'label']);
    expect(labels(board)).toEqual(['English', 'English']);

    // Them → you: board audio reaches their recognizer and starts a conversation (mic on).
    board.emitAudio(packet());
    await flush();
    expect(engine.fed).toHaveLength(1);
    expect(engine.fed[0].sampleRate).toBe(16000);
    expect(engine.fed[0].pcm.length).toBe(40);
    expect(engine.micStates).toEqual([true]);
    expect(c.getState().listening).toBe(true);

    engine.emit('theirs', {text: 'Where is the market?', confidence: 0.9, generation: 0});
    engine.emit('theirs', {text: 'How much is it?', confidence: null, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([
      {text: 'vi:Where is the market?', id: 1},
      {text: 'vi:How much is it?', id: 2},
    ]);
    expect(c.getState().theirLines.map(l => [l.source, l.target])).toEqual([
      ['Where is the market?', 'vi:Where is the market?'],
      ['How much is it?', 'vi:How much is it?'],
    ]);
    expect(engine.translateCalls.map(x => [x.from, x.to])).toEqual([
      ['en', 'vi'],
      ['en', 'vi'],
    ]);

    // You → them: Vietnamese turns become subtitles on the board.
    advance(3000);
    engine.emit('mine', {kind: 'partial', text: 'chợ ở', startMs: 0, endMs: 500});
    await flush();
    expect(c.getState().myPartial).toBe('chợ ở');
    engine.emit('mine', {kind: 'finalText', text: 'chợ ở bên trái', startMs: 0, endMs: 900});
    await flush();
    const mine = c.getState().myLines;
    expect(mine).toHaveLength(1);
    expect(mine[0].source).toBe('chợ ở bên trái');
    expect(mine[0].target).toMatch(/^en:.*bên trái/);
    expect(subtitles(board).at(-1)?.text).toBe(mine[0].target);
    expect(engine.translateCalls.at(-1)).toMatchObject({from: 'vi', to: 'en'});

    // The idle check ends the conversation after ten quiet minutes.
    advance(600_001);
    jest.advanceTimersByTime(5000);
    await flush();
    expect(c.getState().listening).toBe(false);
    expect(engine.micStates).toEqual([true, false]);
  });

  it('defaults to English, shows the language list when the saved pick is gone', async () => {
    const {c} = setup({pick: new MemoryPickStore('xx')});
    await c.start();
    await flush();
    expect(c.currentSession.state).toEqual({type: 'choosing', reason: 'unavailable'});
    expect(c.getState().phase).toBe('needsDownload');
    expect(c.getState().offeredPacks.map(p => p.code)).toEqual(['en', 'fr', 'ja']);
    c.pickLanguage('ja');
    await flush();
    expect(c.currentSession.state.type).toBe('running');
    expect(c.getState().currentCode).toBe('ja');
  });

  it('keeps the pick across a new controller', async () => {
    const pick = new MemoryPickStore();
    const first = await running({pick});
    first.c.pickLanguage('fr');
    await flush();
    expect(pick.code).toBe('fr');
    first.c.dispose();

    const second = await running({pick});
    expect(second.engine.missingCalls[0].other).toBe('fr');
    expect(second.engine.starts[0].pair.other).toBe('fr');
    expect(second.c.getState().languageLabel).toBe('Français');
  });

  it('a switch drops what the old pair had queued: nothing old is spoken (Review Focus 2)', async () => {
    const {engine, board, c} = await running();
    board.emitState('ready');
    await flush();
    engine.hold = true;
    engine.emit('theirs', {text: 'First old phrase', confidence: 0.9, generation: 0});
    engine.emit('theirs', {text: 'Second old phrase', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.translateCalls).toHaveLength(1); // the first is translating, the second waits

    c.pickLanguage('fr');
    await flush();
    expect(engine.stopSpeakingCount).toBe(1);
    engine.release();
    await flush();
    expect(c.currentSession).toEqual({
      state: {type: 'running', code: 'fr', restarts: 0},
      generation: 1,
    });
    expect(engine.starts.at(-1)?.pair).toEqual({home: 'vi', other: 'fr', generation: 1});
    // A late result of the old generation is dropped too.
    engine.emit('theirs', {text: 'Late old phrase', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([]);
    expect(c.getState().theirLines).toEqual([]);
    expect(engine.translateCalls.map(x => x.text)).toEqual(['First old phrase']);

    engine.emit('theirs', {text: 'Bonjour madame', confidence: null, generation: 1});
    await flush();
    expect(engine.spoken).toEqual([{text: 'vi:Bonjour madame', id: 1}]);
    expect(engine.translateCalls.at(-1)).toMatchObject({from: 'fr', to: 'vi'});
    expect(labels(board)).toEqual(['English', 'English', 'Français']);
  });

  it('sends the clock and the label on every ready and the label on a switch', async () => {
    const {board, c} = setup();
    board.emitState('ready'); // before the session: only the clock (no language yet)
    await c.start();
    await flush();
    expect(board.sentTexts.map(s => s.kind)).toEqual(['time', 'label']);
    expect(board.sentTexts[0].text).toMatch(/^1700000000 -?\d+$/);
    expect(labels(board)).toEqual(['English']);

    board.emitState('scanning');
    board.emitState('ready');
    await flush();
    expect(board.sentTexts.map(s => s.kind)).toEqual(['time', 'label', 'time', 'label']);

    c.pickLanguage('ja');
    await flush();
    // An old board draws Latin only: the Latin label.
    expect(labels(board)).toEqual(['English', 'English', 'JA']);
  });

  it('sends a label in its own script when the board has the font', async () => {
    const glyphs = new BoardGlyphSets({cjk: [...'日本語'].map(ch => [ch.codePointAt(0)!, ch.codePointAt(0)!] as const)});
    const board = new FakeBoardLink();
    board.info = {protocolVersion: 1, fontSets: FontSets.latinVI.or(FontSets.cjk)};
    const {c} = await running({board, glyphs, pick: new MemoryPickStore('ja')});
    expect(c.getState().currentCode).toBe('ja');
    expect(labels(board)).toEqual(['日本語']);
  });

  it('restarts a dead recognizer once, then fails while my side keeps running', async () => {
    const {engine, board, c, advance} = await running();
    engine.failNext('feedTheirAudio', new EngineError('notReady'));
    board.emitAudio(packet());
    await flush();
    expect(engine.stopCount).toBe(1);
    expect(engine.starts).toHaveLength(2);
    expect(c.currentSession.state).toEqual({type: 'running', code: 'en', restarts: 1});

    engine.failNext('feedTheirAudio', new EngineError('notReady'));
    board.emitAudio(packet());
    await flush();
    expect(c.currentSession.state).toEqual({type: 'failed', code: 'en', reason: 'recognizer stopped'});
    expect(c.getState().phase).toBe('failed');
    expect(c.getState().message).toBe(t('failed.recognizerStopped'));
    expect(engine.stopCount).toBe(1);

    advance(3000);
    engine.emit('mine', {kind: 'finalText', text: 'cảm ơn', startMs: 0, endMs: 500});
    await flush();
    expect(subtitles(board).at(-1)?.text).toMatch(/^en:/);

    // Retry restarts the same pair (the engine's start alone is a no-op for a running pair).
    c.onRetry();
    await flush();
    expect(c.currentSession.state.type).toBe('running');
    expect(engine.stopCount).toBe(2);
    expect(engine.starts).toHaveLength(3);
  });

  it('skips their phrase when the translator throws, keeps my source text', async () => {
    const {engine, board, c, advance} = await running();
    engine.failNextTranslate();
    engine.emit('theirs', {text: 'Broken phrase', confidence: 0.9, generation: 0});
    engine.emit('theirs', {text: 'Good phrase', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([{text: 'vi:Good phrase', id: 1}]);
    expect(c.getState().theirLines.map(l => l.source)).toEqual(['Good phrase']);

    advance(3000);
    engine.failNextTranslate();
    engine.emit('mine', {kind: 'finalText', text: 'tôi muốn mua cái này', startMs: 0, endMs: 900});
    await flush();
    expect(c.getState().myLines[0].target).toBe('tôi muốn mua cái này');
    expect(subtitles(board).at(-1)?.text).toBe('tôi muốn mua cái này');
  });

  it('shows an unclear phrase dimmed, speaks only the cue, never its translation', async () => {
    const {engine, c} = await running();
    engine.emit('theirs', {text: 'mumble mumble', confidence: 0.2, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([{text: t('cue.unclear'), id: 1}]);
    expect(engine.translateCalls).toEqual([]);
    expect(c.getState().theirLines).toMatchObject([
      {source: 'mumble mumble', target: t('line.unclear'), unclear: true},
    ]);
  });

  it('drops their phrase while I speak (the board mic hears me)', async () => {
    const {engine, c, advance} = await running();
    engine.emit('mine', {kind: 'partial', text: 'xin chào', startMs: 0, endMs: 300});
    engine.emit('theirs', {text: 'echo of you', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([]);
    engine.emit('mine', {kind: 'finalText', text: 'xin chào', startMs: 0, endMs: 400});
    advance(1500);
    engine.emit('theirs', {text: 'Hello to you', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([{text: 'vi:Hello to you', id: 1}]);
    expect(c.getState().theirLines).toHaveLength(1);
  });

  it('without a Vietnamese voice shows the banner and still shows the text', async () => {
    const engine = new ScriptedEngine(caps());
    engine.missingResult = [{kind: 'ttsVoice', language: 'vi'}];
    const {c} = await running({engine});
    expect(c.getState().ttsVoiceMissing).toBe(true);
    engine.emit('theirs', {text: 'Good morning', confidence: 0.9, generation: 0});
    await flush();
    expect(c.getState().theirLines.map(l => l.target)).toEqual(['vi:Good morning']);
    c.openTtsSettings();
    await flush();
    expect(engine.openTtsSettingsCount).toBe(1);
  });

  it('a glossary term goes to the recognizers and is masked in the next phrase', async () => {
    const kv = new MemoryKeyValueStore();
    const {engine, board, c, advance} = await running({openGlossary: () => GlossaryStore.open(kv)});
    await c.addTerm('Bến Thành');
    await flush();
    expect(c.getState().glossaryTerms.map(x => x.text)).toEqual(['Bến Thành']);
    expect(engine.hints).toContain('Bến Thành');

    advance(3000);
    engine.emit('mine', {kind: 'finalText', text: 'tôi muốn đi chợ Bến Thành', startMs: 0, endMs: 900});
    await flush();
    const asked = engine.translateCalls.at(-1)!;
    expect(asked).toMatchObject({from: 'vi', to: 'en'});
    expect(asked.text).not.toContain('Bến Thành');
    expect(asked.text).toMatch(/Zorvik1/);
    expect(c.getState().myLines[0].target).toContain('Bến Thành');
    expect(subtitles(board).at(-1)?.text).toContain('Bến Thành');

    await expect(c.addTerm('  ')).rejects.toEqual(new GlossaryValidationError(GlossaryMessages.empty));
    await expect(c.addTerm('bến thành')).rejects.toEqual(
      new GlossaryValidationError(GlossaryMessages.duplicate),
    );
    const id = c.getState().glossaryTerms[0].id;
    await c.updateTerm(id, 'Chợ Lớn');
    await c.deleteTerm(id);
    await flush();
    expect(c.getState().glossaryTerms).toEqual([]);
  });

  it('works on the phone without a board ("no board")', async () => {
    const {engine, board, c, advance} = await running();
    expect(c.getState().board).toBe('off');
    c.startListening();
    await flush();
    expect(c.getState().listening).toBe(true);
    expect(engine.micStates).toEqual([true]);
    engine.emit('theirs', {text: 'Hello there', confidence: 0.9, generation: 0});
    advance(3000);
    engine.emit('mine', {kind: 'finalText', text: 'chào anh', startMs: 0, endMs: 500});
    await flush();
    expect(engine.spoken).toHaveLength(1);
    expect(c.getState().myLines[0].target).toMatch(/^en:/);
    expect(labels(board)).toEqual(['English']); // a link that is not ready drops it
    c.stopListening();
    await flush();
    expect(c.getState().listening).toBe(false);
    expect(engine.micStates).toEqual([true, false]);
  });

  it('does not start without the microphone permission and explains why', async () => {
    let granted = false;
    const permissions: PermissionGate = {session: async () => granted, board: async () => true};
    const {engine, c} = setup({permissions});
    await c.start();
    await flush();
    expect(c.currentSession.state).toMatchObject({type: 'failed', code: 'en'});
    expect(c.getState().phase).toBe('failed');
    expect(c.getState().message).toBe(t('permission.microphone'));
    expect(engine.starts).toEqual([]);

    granted = true;
    c.onRetry();
    await flush();
    expect(c.currentSession.state.type).toBe('running');
    expect(engine.starts).toHaveLength(1);
  });

  it('downloads what is missing, with progress, and retries a failed download', async () => {
    const engine = new ScriptedEngine(caps());
    const missing: MissingMsg[] = [
      {kind: 'speechModel', language: 'en'},
      {kind: 'translation', language: 'en', from: 'en', to: 'vi'},
    ];
    engine.missingResult = missing;
    const {c} = setup({engine});
    await c.start();
    await flush();
    expect(c.currentSession.state).toEqual({type: 'needsDownload', code: 'en', missing, error: null});
    expect(c.getState().session).toEqual(c.currentSession.state);

    engine.failNext('downloadItem', new EngineError('downloadFailed', 'no network'));
    c.onDownload();
    expect(c.currentSession.state.type).toBe('downloading');
    engine.emit('download', {item: missing[0], progress: 0.5, done: false, error: null});
    expect(c.getState().downloadProgress).toBe(0.25);
    await flush();
    expect(c.currentSession.state).toMatchObject({type: 'needsDownload', error: 'no network'});

    // Retry asks the engine again (everything still missing here), then checks once more.
    const answers: MissingMsg[][] = [missing, []];
    engine.missing = async () => answers.shift() ?? [];
    c.onRetry();
    expect(c.currentSession.state.type).toBe('downloading');
    await flush();
    expect(engine.downloaded).toEqual(missing);
    expect(engine.capabilitiesCalls).toEqual(['vi', 'vi']);
    expect(c.currentSession.state.type).toBe('running');
    expect(c.getState().downloadProgress).toBeNull();
  });

  it('tries the next recognizer of the chain when one cannot start', async () => {
    const engine = new ScriptedEngine({...caps(), recognizers: {en: ['osOnDevice', 'whisper']}});
    engine.failNext('start', new EngineError('notReady', 'no on-device recognizer'));
    const {c} = await running({engine});
    expect(engine.starts.map(s => s.recognizerX)).toEqual(['whisper']);
    expect(c.getState().onlineRecognizer).toBe(false);
  });

  it('lists online-only languages with consent and remembers it', async () => {
    const settings = new MemoryKeyValueStore();
    const engine = new ScriptedEngine({...caps(), recognizers: {...caps().recognizers, de: ['osOnline']}, translatable: new Set(['vi', 'en', 'fr', 'ja', 'de'])});
    const {c} = await running({engine, settings});
    expect(c.getState().onlineCandidates.map(p => p.code)).toEqual(['de']);
    c.setOnlineAllowed('de', true);
    await flush();
    expect(c.getState().offeredPacks.map(p => p.code)).toContain('de');
    expect(c.getState().onlineCodes).toEqual(['de']);
    expect(JSON.parse(settings.items.get('onlineAllowed')!)).toEqual(['de']);

    const again = await running({engine: new ScriptedEngine(engine.capabilitiesResult), settings});
    expect(again.c.getState().onlineAllowed).toEqual(['de']);
  });

  it('the board mic starts a conversation only when it goes from off to on', async () => {
    const {board, c, engine} = await running();
    c.stopListening();
    await flush();
    expect(engine.micStates).toEqual([true, false]);
    // Already on: a repeated "on" is no tap.
    board.emitControl({type: 'micChanged', on: true});
    await flush();
    expect(c.getState().listening).toBe(false);

    c.toggleBoardMic();
    expect(board.micCalls).toEqual([false]);
    expect(c.getState().boardMicOn).toBe(false);
    board.emitControl({type: 'micChanged', on: true});
    await flush();
    expect(c.getState().boardMicOn).toBe(true);
    expect(c.getState().listening).toBe(true);
    expect(engine.micStates).toEqual([true, false, true]);

    c.stopListening();
    c.toggleBoardMic(); // on → off
    c.toggleBoardMic(); // off → on: a tap
    await flush();
    expect(board.micCalls).toEqual([false, false, true]);
    expect(c.getState().listening).toBe(true);
  });

  // --- fix round 1 -------------------------------------------------------------------------

  it('opening the app starts listening once the session first runs', async () => {
    const {c, engine} = await running();
    expect(c.getState().listening).toBe(true);
    expect(engine.micStates).toEqual([true]);
    c.stopListening();
    c.pickLanguage('fr'); // a later running is no launch
    await flush();
    expect(c.currentSession.state.type).toBe('running');
    expect(c.getState().listening).toBe(false);
    expect(engine.micStates).toEqual([true, false]);
  });

  it('speaks the unclear cue at most once per 4 s, the line still dimmed', async () => {
    const {engine, c, advance} = await running();
    engine.emit('theirs', {text: 'mumble one', confidence: 0.2, generation: 0});
    advance(1000);
    engine.emit('theirs', {text: 'mumble two', confidence: 0.2, generation: 0});
    await flush();
    expect(engine.spoken).toEqual([{text: t('cue.unclear'), id: 1}]);
    advance(4001);
    engine.emit('theirs', {text: 'mumble three', confidence: 0.2, generation: 0});
    await flush();
    expect(engine.spoken.map(s => s.text)).toEqual([t('cue.unclear'), t('cue.unclear')]);
    expect(c.getState().theirLines.every(l => l.unclear === true)).toBe(true);
    expect(engine.translateCalls).toEqual([]);
  });

  it('the echo hold clears their pending partial', async () => {
    const {engine, c} = await running();
    engine.emit('mine', {kind: 'partial', text: 'xin chào', startMs: 0, endMs: 300});
    engine.emit('theirs', {text: 'echo of you', confidence: 0.9, generation: 0});
    await flush();
    expect(c.getState().theirPartial).toBe('');
    expect(engine.spoken).toEqual([]);
  });

  it('writes to the board one at a time, in order (subtitles too)', async () => {
    const events: string[] = [];
    class SlowBoard extends FakeBoardLink {
      busy = false;
      async sendText(text: string, kind: 'subtitle' | 'status' | 'time' | 'label'): Promise<void> {
        if (this.busy) {
          throw new Error('overlapping board write');
        }
        this.busy = true;
        events.push(`${kind}:${text}`);
        await new Promise<void>(r => setTimeout(r, 50));
        this.busy = false;
        return super.sendText(text, kind);
      }
    }
    const board = new SlowBoard();
    const {engine, advance, logs} = await running({board});
    board.emitState('ready');
    advance(3000);
    engine.emit('mine', {kind: 'finalText', text: 'chào anh', startMs: 0, endMs: 500});
    for (let i = 0; i < 10; i++) {
      await flush();
      jest.advanceTimersByTime(50);
    }
    await flush();
    expect(logs.filter(l => l.includes('overlapping'))).toEqual([]);
    expect(board.sentTexts.map(s => s.kind)).toEqual(['label', 'time', 'label', 'subtitle']);
    expect(events).toHaveLength(4);
  });

  it('after a recognizer restart retakes the mic only if the conversation was active', async () => {
    const active = await running();
    active.engine.failNext('feedTheirAudio', new EngineError('notReady'));
    active.board.emitAudio(packet());
    await flush();
    expect(active.engine.starts).toHaveLength(2);
    expect(active.engine.micStates).toEqual([true, true]);

    const idle = await running();
    idle.c.stopListening();
    await flush();
    idle.engine.failNext('feedTheirAudio', new EngineError('notReady'));
    idle.board.emitAudio(packet());
    await flush();
    expect(idle.engine.starts).toHaveLength(2);
    // The packet is board audio, but a stop tap keeps automatic starts off until the next tap.
    expect(idle.engine.micStates).toEqual([true, false]);
  });

  it('a refused Bluetooth permission shows the message; the phone side keeps working', async () => {
    const permissions: PermissionGate = {session: async () => true, board: async () => false};
    const {engine, c} = await running({permissions});
    expect(c.getState().boardPermissionRefused).toBe(true);
    expect(c.getState().board).toBe('off');
    engine.emit('theirs', {text: 'Hello there', confidence: 0.9, generation: 0});
    await flush();
    expect(engine.spoken).toHaveLength(1);

    const ok = await running();
    expect(ok.c.getState().boardPermissionRefused).toBe(false);
  });

  it('clears the voice banner when the voice appears', async () => {
    const engine = new ScriptedEngine(caps());
    engine.missingResult = [
      {kind: 'ttsVoice', language: 'vi'},
      {kind: 'speechModel', language: 'en'},
    ];
    const {c} = setup({engine});
    await c.start();
    await flush();
    expect(c.getState().ttsVoiceMissing).toBe(true);
    engine.missingResult = [];
    c.onDownload();
    await flush();
    expect(c.currentSession.state.type).toBe('running');
    expect(c.getState().ttsVoiceMissing).toBe(false);
  });

  it('a retried download fetches only what is still missing', async () => {
    const engine = new ScriptedEngine(caps());
    const model: MissingMsg = {kind: 'speechModel', language: 'en'};
    const translation: MissingMsg = {kind: 'translation', language: 'en', from: 'en', to: 'vi'};
    engine.missingResult = [model, translation];
    const {c} = setup({engine});
    await c.start();
    await flush();
    // The model arrives, the translation fails.
    const download = engine.downloadItem.bind(engine);
    let calls = 0;
    engine.downloadItem = async item => {
      calls++;
      if (calls === 2) {
        throw new EngineError('downloadFailed', 'no network');
      }
      return download(item);
    };
    c.onDownload();
    await flush();
    expect(c.currentSession.state).toMatchObject({type: 'needsDownload', error: 'no network'});
    engine.missingResult = [translation];
    c.onRetry();
    await flush();
    expect(engine.downloaded).toEqual([model, translation]);
  });

  it('notes board audio for the activity at most once per second', async () => {
    const activity = new ConversationActivity();
    const handle = jest.spyOn(activity, 'handle');
    const {board, advance} = await running({activity});
    board.emitAudio(packet());
    board.emitAudio(packet());
    advance(500);
    board.emitAudio(packet());
    advance(600);
    board.emitAudio(packet());
    const notes = handle.mock.calls.filter(([e]) => e === 'boardAudio');
    expect(notes).toHaveLength(2);
  });

  it('clears the history and the board subtitle', async () => {
    const {engine, board, c, advance} = await running();
    advance(3000);
    engine.emit('mine', {kind: 'finalText', text: 'chào anh', startMs: 0, endMs: 500});
    await flush();
    c.clearHistory();
    await flush();
    expect(c.getState().myLines).toEqual([]);
    expect(subtitles(board).at(-1)?.text).toBe('');
  });

  it('publishes every change to subscribers and stops on dispose', async () => {
    const {engine, c} = setup();
    const seen: string[] = [];
    const unsubscribe = c.subscribe(s => seen.push(s.phase));
    await c.start();
    await flush();
    expect(seen).toContain('preparing');
    expect(seen.at(-1)).toBe('running');
    unsubscribe();
    c.dispose();
    expect(engine.stopCount).toBe(1);
    expect(engine.listenerCount('theirs')).toBe(0);
  });
});
