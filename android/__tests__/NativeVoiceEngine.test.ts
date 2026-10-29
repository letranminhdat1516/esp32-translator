// NativeVoiceEngineAdapter over a fake TurboModule (the Kotlin module is track T4).
import fs from 'fs';
import path from 'path';
import {TurboModuleRegistry} from 'react-native';
import type {EventSubscription} from 'react-native';
import {
  NativeAudioSessionMsg,
  NativeDownloadMsg,
  NativeMineMsg,
  NativeTheirsMsg,
  NativeVoiceEngineAdapter,
  Spec,
  voiceEngineModuleName,
} from '../src/engine/NativeVoiceEngine';
import {EngineError} from '../src/engine/VoiceEngine';

/** A codegen `EventEmitter<T>` the test can fire. */
function emitter<T>() {
  const handlers = new Set<(v: T) => void>();
  const fn = (h: (v: T) => void | Promise<void>): EventSubscription => {
    const wrapped = (v: T) => {
      h(v);
    };
    handlers.add(wrapped);
    return {remove: () => handlers.delete(wrapped)};
  };
  return Object.assign(fn, {
    fire: (v: T) => handlers.forEach(h => h(v)),
    count: () => handlers.size,
  });
}

function nativeError(code: string, message = 'native'): Error {
  return Object.assign(new Error(message), {code});
}

function fakeModule() {
  const events = {
    onMine: emitter<NativeMineMsg>(),
    onTheirs: emitter<NativeTheirsMsg>(),
    onGate: emitter<boolean>(),
    onTtsStart: emitter<number>(),
    onTtsEnd: emitter<number>(),
    onAudioSession: emitter<NativeAudioSessionMsg>(),
    onDownload: emitter<NativeDownloadMsg>(),
  };
  const module = {
    getConstants: () => ({}),
    capabilities: jest.fn(async (_home: string) => ({
      recognizers: [{language: 'ja', kinds: ['osOnDevice', 'whisper']}],
      translatable: ['ja'],
      vietnameseVoice: true,
    })),
    missing: jest.fn(async () => [{kind: 'translation', language: 'ja', from: 'ja', to: 'vi'}]),
    download: jest.fn(async () => {}),
    start: jest.fn(async () => {}),
    stop: jest.fn(async () => {}),
    micOn: jest.fn(async () => {}),
    feedTheirAudio: jest.fn(async () => {}),
    translate: jest.fn(async (text: string) => text.toUpperCase()),
    speak: jest.fn(async () => {}),
    stopSpeaking: jest.fn(async () => {}),
    setHints: jest.fn(async () => {}),
    openTtsSettings: jest.fn(async () => {}),
    ...events,
  };
  const spec: Spec = module;
  return {module, events, spec};
}

test('calls go through with the wire types', async () => {
  const {module, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  const caps = await engine.capabilities('vi');
  expect(module.capabilities).toHaveBeenCalledWith('vi');
  expect(caps.recognizers).toEqual({ja: ['osOnDevice', 'whisper']});
  expect([...caps.translatable]).toEqual(['ja']);

  const pair = {home: 'vi', other: 'ja', generation: 3};
  expect(await engine.missing(pair)).toEqual([{kind: 'translation', language: 'ja', from: 'ja', to: 'vi'}]);
  expect(module.missing).toHaveBeenCalledWith(pair);

  await engine.downloadItem({kind: 'speechModel', language: 'ja'});
  expect(module.download).toHaveBeenCalledWith({kind: 'speechModel', language: 'ja', from: null, to: null});
  await engine.start(pair, 'whisper', ['x']);
  expect(module.start).toHaveBeenCalledWith(pair, 'whisper', ['x']);
  await engine.micOn(true);
  expect(module.micOn).toHaveBeenCalledWith(true);
  expect(await engine.translate('hi', 'en', 'vi')).toBe('HI');
  expect(module.translate).toHaveBeenCalledWith('hi', 'en', 'vi');
  await engine.speak('chào', 9);
  expect(module.speak).toHaveBeenCalledWith('chào', 9);
  await engine.setHints(['h']);
  expect(module.setHints).toHaveBeenCalledWith(['h']);
  await engine.stopSpeaking();
  await engine.openTtsSettings();
  await engine.stop();
  expect(module.stopSpeaking).toHaveBeenCalledTimes(1);
  expect(module.openTtsSettings).toHaveBeenCalledTimes(1);
  expect(module.stop).toHaveBeenCalledTimes(1);
});

test('PCM crosses as base64 of 16-bit little-endian samples', async () => {
  const {module, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  await engine.feedTheirAudio(Int16Array.from([1, -2, 300]), 16000);
  const [b64, rate] = module.feedTheirAudio.mock.calls[0] as unknown as [string, number];
  expect(rate).toBe(16000);
  expect(Array.from(Buffer.from(b64, 'base64'))).toEqual([1, 0, 0xfe, 0xff, 0x2c, 0x01]);
});

describe('native errors', () => {
  test('a code naming an EngineError arrives as it', async () => {
    const {module, spec} = fakeModule();
    module.speak.mockRejectedValueOnce(nativeError('notReady', 'no session'));
    const e = await new NativeVoiceEngineAdapter(spec).speak('x', 1).catch((x: unknown) => x);
    expect(e).toBeInstanceOf(EngineError);
    expect((e as EngineError).code).toBe('notReady');
    expect((e as EngineError).message).toBe('no session');
  });

  test('translate and download fall back to their own code', async () => {
    const {module, spec} = fakeModule();
    const engine = new NativeVoiceEngineAdapter(spec);
    module.translate.mockRejectedValueOnce(nativeError('E_UNKNOWN'));
    module.download.mockRejectedValueOnce(new Error('plain'));
    await expect(engine.translate('a', 'en', 'vi')).rejects.toMatchObject({code: 'translateFailed'});
    await expect(engine.downloadItem({kind: 'ttsVoice', language: 'vi'})).rejects.toMatchObject({
      code: 'downloadFailed',
    });
  });

  test('anything else is passed through unchanged', async () => {
    const {module, spec} = fakeModule();
    const original = nativeError('E_UNKNOWN');
    module.start.mockRejectedValueOnce(original);
    await expect(
      new NativeVoiceEngineAdapter(spec).start({home: 'vi', other: 'en', generation: 0}, 'whisper', []),
    ).rejects.toBe(original);
  });
});

test('native events reach the subscribers, typed', () => {
  const {events, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  const got: unknown[] = [];
  engine.on('mine', m => got.push(m));
  engine.on('theirs', m => got.push(m));
  engine.on('gate', m => got.push(m));
  engine.on('ttsStart', m => got.push(['s', m]));
  engine.on('ttsEnd', m => got.push(['e', m]));
  engine.on('audioSession', m => got.push(m));
  engine.on('download', m => got.push(m));
  events.onMine.fire({kind: 'partial', text: 'x', startMs: 1, endMs: 2});
  events.onTheirs.fire({text: 'y', confidence: 0.5, generation: 2});
  events.onGate.fire(false);
  events.onTtsStart.fire(5);
  events.onTtsEnd.fire(5);
  events.onAudioSession.fire({kind: 'interrupted', route: null});
  events.onDownload.fire({
    item: {kind: 'speechModel', language: 'ja', from: null, to: null},
    progress: 0.25,
    done: false,
    error: null,
  });
  expect(got).toEqual([
    {kind: 'partial', text: 'x', startMs: 1, endMs: 2},
    {text: 'y', confidence: 0.5, generation: 2},
    false,
    ['s', 5],
    ['e', 5],
    {kind: 'interrupted', route: null},
    {item: {kind: 'speechModel', language: 'ja', from: null, to: null}, progress: 0.25, done: false, error: null},
  ]);
});

test('an event with an unknown enum name is dropped, not forwarded', () => {
  const {events, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  const got: unknown[] = [];
  engine.on('mine', m => got.push(m));
  engine.on('audioSession', m => got.push(m));
  const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
  events.onMine.fire({kind: 'final', text: 'x', startMs: 0, endMs: 0});
  events.onAudioSession.fire({kind: 'resumed', route: 'speaker'});
  expect(got).toEqual([]);
  expect(warn).toHaveBeenCalledTimes(2);
  warn.mockRestore();
});

test('a throwing handler is logged, never thrown into the native emitter; other handlers still run', () => {
  const {events, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  const got: number[] = [];
  const boom = new Error('handler bug');
  engine.on('ttsEnd', () => {
    throw boom;
  });
  engine.on('ttsEnd', id => got.push(id));
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  expect(() => events.onTtsEnd.fire(3)).not.toThrow();
  expect(got).toEqual([3]);
  expect(error).toHaveBeenCalledTimes(1);
  expect(error.mock.calls[0]).toContain(boom);
  error.mockRestore();
});

test('dispose removes the native subscriptions and the handlers', () => {
  const {events, spec} = fakeModule();
  const engine = new NativeVoiceEngineAdapter(spec);
  expect(events.onGate.count()).toBe(1);
  const got: boolean[] = [];
  engine.on('gate', g => got.push(g));
  engine.dispose();
  events.onGate.fire(true);
  expect(got).toEqual([]);
  expect(Object.values(events).map(e => e.count())).toEqual([0, 0, 0, 0, 0, 0, 0]);
});

test('the module is looked up lazily under its codegen name', () => {
  const {spec} = fakeModule();
  const lookup = jest.spyOn(TurboModuleRegistry, 'getEnforcing').mockReturnValue(spec);
  const engine = new NativeVoiceEngineAdapter();
  expect(lookup).toHaveBeenCalledWith(voiceEngineModuleName);
  expect(voiceEngineModuleName).toBe('VoiceEngine');
  engine.dispose();
  lookup.mockRestore();
});

test('codegenConfig names the spec and the Android package', () => {
  const pkg = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../package.json'), 'utf8'));
  expect(pkg.codegenConfig).toEqual({
    name: 'VoiceEngineSpec',
    type: 'modules',
    jsSrcsDir: 'src/engine',
    android: {javaPackageName: 'vn.cicca.livetranslator.engine'},
  });
});
