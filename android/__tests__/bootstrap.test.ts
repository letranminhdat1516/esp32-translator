// src/app/bootstrap.ts (the real graph, native modules mocked) and src/app/permissions.ts.
import {BoardGlyphSets} from '../src/core/boardGlyphs';
import {FontSets} from '../src/core/model';
import {
  androidPermissionGate,
  requestSessionPermissions,
  sessionPermissionsFor,
} from '../src/app/permissions';
import type {PermissionRequester} from '../src/board/BleAdapter';

const mockDestroy = jest.fn();
const mockRemove = jest.fn();
jest.mock('react-native-ble-plx', () => ({
  BleManager: jest.fn().mockImplementation(() => ({
    onStateChange: () => ({remove: mockRemove}),
    destroy: mockDestroy,
  })),
}));
jest.mock('../src/engine/NativeVoiceEngine', () => {
  const {FakeVoiceEngine} = jest.requireActual('../src/engine/FakeVoiceEngine');
  return {NativeVoiceEngineAdapter: FakeVoiceEngine};
});
jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {getItem: async () => null, setItem: async () => {}, removeItem: async () => {}},
}));

describe('createAppGraph', () => {
  beforeEach(() => BoardGlyphSets.resetShared());

  it('loads the board glyph lists before anything renders and builds the controller', () => {
    const {createAppGraph} = require('../src/app/bootstrap') as typeof import('../src/app/bootstrap');
    const {controller} = createAppGraph();
    expect(controller.getState().phase).toBe('needsDownload');
    expect(controller.getState().session).toEqual({type: 'loading'});
    // The loaded lists are the bundled ones: a CJK board can draw 日.
    expect(BoardGlyphSets.shared.rangesFor(FontSets.cjk).length).toBeGreaterThan(0);
    expect(BoardGlyphSets.load()).toBe(BoardGlyphSets.shared);
    controller.dispose();
  });

  it('destroy disposes the controller, the board link and the BleManager', () => {
    const {createAppGraph} = require('../src/app/bootstrap') as typeof import('../src/app/bootstrap');
    const graph = createAppGraph();
    const dispose = jest.spyOn(graph.controller, 'dispose');
    mockDestroy.mockClear();
    mockRemove.mockClear();
    graph.destroy();
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(mockRemove).toHaveBeenCalled(); // the link dropped its power subscription
    expect(mockDestroy).toHaveBeenCalledTimes(1);
  });
});

describe('permission requests never overlap', () => {
  /** A PermissionsAndroid that throws when a request starts while another is still open. */
  function strictRequester() {
    let open = false;
    const asked: string[][] = [];
    const answer = async (ps: string[]) => {
      if (open) {
        throw new Error('concurrent permission request');
      }
      open = true;
      asked.push(ps);
      await new Promise<void>(r => setTimeout(r, 10));
      open = false;
      return Object.fromEntries(ps.map(p => [p, 'granted']));
    };
    const requester: PermissionRequester = {
      request: async p => (await answer([p]))[p],
      requestMultiple: async ps => answer(ps),
    };
    return {requester, asked};
  }

  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('Bluetooth first, the session after it; a second ask reuses the pending one', async () => {
    const {requester, asked} = strictRequester();
    const gate = androidPermissionGate({OS: 'android', Version: 34}, requester);
    const results = Promise.all([gate.session(), gate.board(), gate.session(), gate.board()]);
    await jest.advanceTimersByTimeAsync(100);
    expect(await results).toEqual([true, true, true, true]);
    expect(asked).toEqual([
      ['android.permission.BLUETOOTH_SCAN', 'android.permission.BLUETOOTH_CONNECT'],
      ['android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS'],
    ]);
    // Later asks run again (the user may have changed the settings), still one at a time.
    const again = Promise.all([gate.board(), gate.session()]);
    await jest.advanceTimersByTimeAsync(100);
    expect(await again).toEqual([true, true]);
    expect(asked).toHaveLength(4);
  });
});

describe('permissions', () => {
  const requester = (results: Record<string, string>): PermissionRequester & {asked: string[][]} => {
    const asked: string[][] = [];
    return {
      asked,
      request: async p => {
        asked.push([p]);
        return results[p] ?? 'denied';
      },
      requestMultiple: async ps => {
        asked.push(ps);
        return Object.fromEntries(ps.map(p => [p, results[p] ?? 'denied']));
      },
    };
  };

  it('asks for the microphone, and notifications from Android 13', async () => {
    expect(sessionPermissionsFor(29)).toEqual(['android.permission.RECORD_AUDIO']);
    expect(sessionPermissionsFor(33)).toEqual([
      'android.permission.RECORD_AUDIO',
      'android.permission.POST_NOTIFICATIONS',
    ]);
    const r = requester({'android.permission.RECORD_AUDIO': 'granted'});
    expect(await requestSessionPermissions({OS: 'android', Version: 34}, r)).toBe(true);
    expect(r.asked).toEqual([sessionPermissionsFor(34)]);
  });

  it('a refused microphone is a refusal; refused notifications are not', async () => {
    expect(
      await requestSessionPermissions(
        {OS: 'android', Version: 34},
        requester({'android.permission.POST_NOTIFICATIONS': 'granted'}),
      ),
    ).toBe(false);
    expect(
      await requestSessionPermissions({OS: 'android', Version: 29}, requester({})),
    ).toBe(false);
    expect(await requestSessionPermissions({OS: 'ios', Version: 26}, requester({}))).toBe(true);
  });

  it('the gate asks Bluetooth through requestBlePermissions', async () => {
    const r = requester({'android.permission.ACCESS_FINE_LOCATION': 'granted'});
    const gate = androidPermissionGate({OS: 'android', Version: 29}, r);
    expect(await gate.board()).toBe(true);
    expect(r.asked).toEqual([['android.permission.ACCESS_FINE_LOCATION']]);
  });
});
