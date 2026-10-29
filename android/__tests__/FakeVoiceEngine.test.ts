// Port of app/test/engine/fake_voice_engine_test.dart (+ the VoiceEngine helpers it covers).
import {capabilitiesEquals} from '../src/core/model';
import {FakeVoiceEngine} from '../src/engine/FakeVoiceEngine';
import {
  EngineError,
  MineMsg,
  TheirsMsg,
  TypedEmitter,
  VoiceEngine,
  capabilitiesFromMsg,
  engineErrorCodes,
  pcm16leBase64,
} from '../src/engine/VoiceEngine';

test('records speak calls in order', async () => {
  const engine = new FakeVoiceEngine();
  await engine.speak('xin chào', 1);
  await engine.speak('hello', 2);
  expect(engine.spoken).toEqual([
    {text: 'xin chào', id: 1},
    {text: 'hello', id: 2},
  ]);
});

test('failNextTranslate throws once, then translations resume', async () => {
  const engine = new FakeVoiceEngine();
  engine.translations.set('hi', 'chào');
  engine.failNextTranslate();
  const error = await engine.translate('hi', 'en', 'vi').catch((e: unknown) => e);
  expect(error).toBeInstanceOf(EngineError);
  expect((error as EngineError).code).toBe('translateFailed');
  expect(await engine.translate('hi', 'en', 'vi')).toBe('chào');
  expect(await engine.translate('unknown', 'en', 'vi')).toBe('unknown');
  expect(engine.translateCalls).toEqual([
    {text: 'hi', from: 'en', to: 'vi'},
    {text: 'hi', from: 'en', to: 'vi'},
    {text: 'unknown', from: 'en', to: 'vi'},
  ]);
});

test('scripted capabilities and missing; calls recorded', async () => {
  const engine: FakeVoiceEngine = new FakeVoiceEngine({
    recognizers: {ja: ['whisper']},
    translatable: new Set(['ja']),
    vietnameseVoice: false,
  });
  const caps = await engine.capabilities('vi');
  expect(caps.recognizers).toEqual({ja: ['whisper']});
  engine.missingResult = [{kind: 'speechModel', language: 'ja'}];
  const pair = {home: 'vi', other: 'ja', generation: 1};
  expect(await engine.missing(pair)).toEqual([{kind: 'speechModel', language: 'ja'}]);
  expect(engine.capabilitiesCalls).toEqual(['vi']);
  expect(engine.missingCalls).toEqual([pair]);
});

test('every other call is recorded', async () => {
  const engine = new FakeVoiceEngine();
  const pair = {home: 'vi', other: 'en', generation: 2};
  const pcm = Int16Array.from([1, -1]);
  await engine.downloadItem({kind: 'translation', language: 'en', from: 'en', to: 'vi'});
  await engine.start(pair, 'whisper', ['Tuấn']);
  await engine.micOn(true);
  await engine.micOn(false);
  await engine.feedTheirAudio(pcm, 16000);
  await engine.setHints(['a']);
  await engine.stopSpeaking();
  await engine.openTtsSettings();
  await engine.stop();
  expect(engine.downloaded).toEqual([{kind: 'translation', language: 'en', from: 'en', to: 'vi'}]);
  expect(engine.starts).toEqual([{pair, recognizerX: 'whisper', hints: ['Tuấn']}]);
  expect(engine.micStates).toEqual([true, false]);
  expect(engine.fed).toEqual([{pcm, sampleRate: 16000}]);
  expect(engine.hints).toEqual(['a']);
  expect([engine.stopSpeakingCount, engine.openTtsSettingsCount, engine.stopCount]).toEqual([1, 1, 1]);
});

test('scripted call failures', async () => {
  const engine = new FakeVoiceEngine();
  engine.failNext('downloadItem', new EngineError('downloadFailed', 'no network'));
  await expect(engine.downloadItem({kind: 'ttsVoice', language: 'vi'})).rejects.toMatchObject({
    code: 'downloadFailed',
    message: 'no network',
  });
  await expect(engine.downloadItem({kind: 'ttsVoice', language: 'vi'})).resolves.toBeUndefined();
  engine.failNext('start', new EngineError('notReady'));
  await expect(engine.start({home: 'vi', other: 'en', generation: 0}, 'whisper', [])).rejects.toBeInstanceOf(
    EngineError,
  );
  expect(engine.starts).toHaveLength(0);
  expect(engine.downloaded).toHaveLength(1);
});

test('emitted events arrive at the subscribers', () => {
  const engine: VoiceEngine & FakeVoiceEngine = new FakeVoiceEngine();
  const mine: MineMsg = {kind: 'finalText', text: 'a', startMs: 0, endMs: 10};
  const theirs: TheirsMsg = {text: 'b', confidence: null, generation: 3};
  const got: unknown[] = [];
  engine.on('mine', m => got.push(m));
  engine.on('theirs', m => got.push(m));
  engine.on('gate', open => got.push(open));
  engine.on('ttsStart', id => got.push(['start', id]));
  engine.on('ttsEnd', id => got.push(['end', id]));
  engine.on('audioSession', m => got.push(m));
  engine.on('download', m => got.push(m));
  engine.emit('mine', mine);
  engine.emit('theirs', theirs);
  engine.emit('gate', true);
  engine.emit('ttsStart', 4);
  engine.emit('ttsEnd', 4);
  engine.emit('audioSession', {kind: 'routeChanged', route: 'phoneMic'});
  engine.emit('download', {item: {kind: 'speechModel', language: 'ja'}, progress: 1, done: true, error: null});
  expect(got[0]).toBe(mine);
  expect(got[1]).toBe(theirs);
  expect(got.slice(2, 5)).toEqual([true, ['start', 4], ['end', 4]]);
  expect(got[5]).toEqual({kind: 'routeChanged', route: 'phoneMic'});
  expect((got[6] as {done: boolean}).done).toBe(true);
});

describe('TypedEmitter', () => {
  type Events = {n: number; s: string};

  test('unsubscribe stops delivery; other handlers keep theirs', () => {
    const e = new TypedEmitter<Events>();
    const a: number[] = [];
    const b: number[] = [];
    const offA = e.on('n', x => a.push(x));
    e.on('n', x => b.push(x));
    e.emit('n', 1);
    offA();
    offA(); // idempotent
    e.emit('n', 2);
    expect(a).toEqual([1]);
    expect(b).toEqual([1, 2]);
    expect(e.listenerCount('n')).toBe(1);
    expect(e.listenerCount('s')).toBe(0);
  });

  test('the same handler twice is called twice; a handler removed during emit is skipped next time', () => {
    const e = new TypedEmitter<Events>();
    const seen: string[] = [];
    const h = (s: string) => seen.push(s);
    e.on('s', h);
    const off = e.on('s', h);
    let offSelf = () => {};
    offSelf = e.on('s', () => {
      seen.push('self');
      offSelf();
    });
    e.emit('s', 'x');
    off();
    e.emit('s', 'y');
    expect(seen).toEqual(['x', 'x', 'self', 'y']);
  });

  test('a throwing handler does not starve the others; the first error is rethrown', () => {
    const e = new TypedEmitter<Events>();
    const seen: number[] = [];
    e.on('n', () => {
      throw new Error('boom');
    });
    e.on('n', x => seen.push(x));
    expect(() => e.emit('n', 7)).toThrow('boom');
    expect(seen).toEqual([7]);
  });

  test('removeAll', () => {
    const e = new TypedEmitter<Events>();
    e.on('n', () => {});
    e.on('s', () => {});
    e.removeAll();
    expect(e.listenerCount('n') + e.listenerCount('s')).toBe(0);
  });
});

describe('EngineError', () => {
  test('codes are the Dart enum names', () => {
    expect(engineErrorCodes).toEqual(['translateFailed', 'notReady', 'downloadFailed']);
  });

  test('fromCode', () => {
    expect(EngineError.fromCode('notReady')?.code).toBe('notReady');
    expect(EngineError.fromCode('nope')).toBeNull();
    expect(EngineError.fromCode(undefined)).toBeNull();
  });

  test('is an Error with the code as its default message', () => {
    const e = new EngineError('translateFailed');
    expect(e).toBeInstanceOf(Error);
    expect(e.message).toBe('translateFailed');
    expect(e.name).toBe('EngineError');
  });
});

test('capabilitiesFromMsg maps recognizer names', () => {
  const caps = capabilitiesFromMsg({
    recognizers: [{language: 'ja', kinds: ['whisper', 'osOnline']}],
    translatable: ['ja', 'vi'],
    vietnameseVoice: false,
  });
  expect(
    capabilitiesEquals(caps, {
      recognizers: {ja: ['whisper', 'osOnline']},
      translatable: new Set(['ja', 'vi']),
      vietnameseVoice: false,
    }),
  ).toBe(true);
  expect(() =>
    capabilitiesFromMsg({recognizers: [{language: 'ja', kinds: ['magic']}], translatable: [], vietnameseVoice: true}),
  ).toThrow('unknown recognizer "magic"');
});

test('PCM to base64 keeps sample values (16-bit little-endian)', () => {
  const pcm = Int16Array.from([0, 1, -1, 32767, -32768, 258]);
  const b64 = pcm16leBase64(pcm);
  const bytes = Buffer.from(b64, 'base64');
  expect(bytes.length).toBe(12);
  expect(Array.from(bytes.subarray(0, 6))).toEqual([0, 0, 1, 0, 255, 255]);
  expect(Array.from(new Int16Array(bytes.buffer, bytes.byteOffset, 6))).toEqual([0, 1, -1, 32767, -32768, 258]);
  // A view into a larger buffer must honour its offset.
  const view = Int16Array.from([9, 8, 7, 6]).subarray(1, 3);
  expect(Array.from(new Int16Array(Uint8Array.from(Buffer.from(pcm16leBase64(view), 'base64')).buffer))).toEqual([8, 7]);
  // Every padding length, against Node's encoder.
  for (const n of [0, 1, 2, 3, 4, 5, 160]) {
    const p = Int16Array.from({length: n}, (_, i) => i * 997 - 30000);
    expect(pcm16leBase64(p)).toBe(Buffer.from(p.buffer).toString('base64'));
  }
});
