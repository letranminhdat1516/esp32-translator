// src/app/bootstrap.ts (the real graph, native modules mocked) and src/app/permissions.ts.
import {BoardGlyphSets} from '../src/core/boardGlyphs';
import {FontSets} from '../src/core/model';
import {
  androidPermissionGate,
  requestSessionPermissions,
  sessionPermissionsFor,
} from '../src/app/permissions';
import type {PermissionRequester} from '../src/board/BleAdapter';

jest.mock('react-native-ble-plx', () => ({
  BleManager: jest.fn().mockImplementation(() => ({
    onStateChange: () => ({remove: () => {}}),
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
