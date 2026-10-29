import React from 'react';
import ReactTestRenderer, {act} from 'react-test-renderer';
import {Text} from 'react-native';
import {EngineProbe, measureFeed, probeSession} from '../src/dev/EngineProbe';
import {FakeVoiceEngine} from '../src/engine/FakeVoiceEngine';
import {MissingMsg} from '../src/engine/VoiceEngine';

// The probe echoes its lines to the console in debug builds (logcat evidence on the phone)
beforeEach(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => jest.restoreAllMocks());

function fakeEngine(): FakeVoiceEngine {
  const engine = new FakeVoiceEngine({
    recognizers: {vi: ['whisper', 'osOnline'], en: ['whisper']},
    translatable: new Set(['vi', 'en']),
    vietnameseVoice: true,
  });
  const missing: MissingMsg[] = [
    {kind: 'speechModel', language: 'en', from: null, to: null},
    {kind: 'translation', language: 'en', from: 'vi', to: 'en'},
  ];
  engine.missingResult = missing;
  return engine;
}

describe('probeSession', () => {
  test('asks capabilities for vi, downloads what en is missing, then starts with the best en recognizer', async () => {
    const engine = fakeEngine();
    const log: string[] = [];
    await probeSession(engine, line => log.push(line));
    expect(engine.capabilitiesCalls).toEqual(['vi']);
    expect(engine.missingCalls).toEqual([{home: 'vi', other: 'en', generation: 1}]);
    expect(engine.downloaded).toEqual(engine.missingResult);
    expect(engine.starts).toEqual([
      {pair: {home: 'vi', other: 'en', generation: 1}, recognizerX: 'whisper', hints: []},
    ]);
    expect(engine.micStates).toEqual([true]);
    expect(log.join('\n')).toContain('speechModel en');
  });

  test('a failed download is logged and the session is not started', async () => {
    const engine = fakeEngine();
    engine.failNext('downloadItem', new Error('no network'));
    const log: string[] = [];
    await expect(probeSession(engine, line => log.push(line))).rejects.toThrow('no network');
    expect(engine.starts).toEqual([]);
  });
});

describe('measureFeed', () => {
  test('feeds 20 ms packets of 16 kHz PCM and reports the mean time per packet', async () => {
    const engine = fakeEngine();
    let t = 0;
    const result = await measureFeed(engine, 10, () => (t += 0.5));
    expect(engine.fed).toHaveLength(10);
    expect(engine.fed.every(f => f.pcm.length === 320 && f.sampleRate === 16000)).toBe(true);
    expect(result.packets).toBe(10);
    expect(result.msPerPacket).toBeGreaterThan(0);
  });
});

describe('EngineProbe screen', () => {
  test('shows mine, theirs and gate events as they arrive, and unsubscribes on unmount', async () => {
    const engine = fakeEngine();
    let renderer!: ReactTestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = ReactTestRenderer.create(<EngineProbe engine={engine} />);
    });
    await act(async () => {
      engine.emit('theirs', {text: 'where is the station', confidence: null, generation: 1});
      engine.emit('mine', {kind: 'finalText', text: 'ga ở đâu', startMs: 0, endMs: 900});
      engine.emit('gate', true);
    });
    const texts = renderer.root.findAllByType(Text).map(t => String(t.props.children));
    const all = texts.join('\n');
    expect(all).toContain('theirs: where is the station');
    expect(all).toContain('mine finalText: ga ở đâu');
    expect(all).toContain('gate: open');
    await act(async () => renderer.unmount());
    expect(engine.listenerCount('theirs')).toBe(0);
    expect(engine.listenerCount('mine')).toBe(0);
  });
});

describe('EngineProbe cleanup', () => {
  async function mount(element: React.ReactElement) {
    let renderer!: ReactTestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = ReactTestRenderer.create(element);
    });
    return renderer;
  }

  test('unmounting stops a session it started', async () => {
    const engine = fakeEngine();
    const renderer = await mount(<EngineProbe engine={engine} />);
    const start = renderer.root.find(n => n.props.accessibilityLabel === 'Chạy thử');
    await act(async () => start.props.onPress());
    expect(engine.starts).toHaveLength(1);
    await act(async () => renderer.unmount());
    expect(engine.stopCount).toBe(1);
  });

  test('unmounting without a session does not stop the engine', async () => {
    const engine = fakeEngine();
    const renderer = await mount(<EngineProbe engine={engine} />);
    await act(async () => renderer.unmount());
    expect(engine.stopCount).toBe(0);
  });

  test('the engine the probe creates itself is disposed on unmount', async () => {
    const dispose = jest.fn();
    const created = Object.assign(fakeEngine(), {dispose});
    const renderer = await mount(<EngineProbe createEngine={() => created} />);
    await act(async () => renderer.unmount());
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(created.listenerCount('mine')).toBe(0);
  });

  test('a given engine is not disposed (its owner does that)', async () => {
    const dispose = jest.fn();
    const engine = Object.assign(fakeEngine(), {dispose});
    const renderer = await mount(<EngineProbe engine={engine} />);
    await act(async () => renderer.unmount());
    expect(dispose).not.toHaveBeenCalled();
  });
});
