// BlePlxAdapter against a scripted react-native-ble-plx manager, base64 helpers, and the Android
// permission request.
import type {Characteristic, Device} from 'react-native-ble-plx';
import {
  BlePlxAdapter,
  PermissionRequester,
  PlxManager,
  blePermissionsFor,
  fromBase64,
  requestBlePermissions,
  requestedMtu,
  toBase64,
} from '../src/board/BleAdapter';
import {boardServiceUuid, boardTextUuid} from '../src/board/protocol';

const device = (id: string, mtu: number) => ({id, mtu} as unknown as Device);
const char = (uuid: string, value: string | null = null) =>
  ({uuid, value} as unknown as Characteristic);
const sub = () => ({remove: jest.fn()});

function mockManager() {
  const m = {
    onStateChange: jest.fn(),
    connectedDevices: jest.fn(async () => [] as Device[]),
    startDeviceScan: jest.fn(
      async (_uuids: string[] | null, _options: null, _listener: unknown): Promise<void> => {},
    ),
    stopDeviceScan: jest.fn(async () => {}),
    connectToDevice: jest.fn(async (id: string) => device(id, 247)),
    cancelDeviceConnection: jest.fn(async (id: string) => device(id, 23)),
    onDeviceDisconnected: jest.fn(),
    discoverAllServicesAndCharacteristicsForDevice: jest.fn(async (id: string) => device(id, 247)),
    characteristicsForDevice: jest.fn(async () => [char(boardTextUuid.toLowerCase())]),
    readCharacteristicForDevice: jest.fn(async () => char('x', 'AQMAAAA=')),
    writeCharacteristicWithResponseForDevice: jest.fn(async () => char('x')),
    writeCharacteristicWithoutResponseForDevice: jest.fn(async () => char('x')),
    monitorCharacteristicForDevice: jest.fn(),
  };
  return {m, manager: m as unknown as PlxManager};
}

test('base64 round-trips every length and matches Buffer', () => {
  for (let n = 0; n < 40; n++) {
    const data = Uint8Array.from({length: n}, (_, i) => (i * 37 + n) % 256);
    const b64 = toBase64(data);
    expect(b64).toBe(Buffer.from(data).toString('base64'));
    expect(Array.from(fromBase64(b64))).toEqual(Array.from(data));
  }
  expect(Array.from(fromBase64('AQMAAAA='))).toEqual([1, 3, 0, 0, 0]);
});

test('power: only PoweredOn is on; current state requested; unsubscribe removes', () => {
  const {m, manager} = mockManager();
  const s = sub();
  m.onStateChange.mockReturnValue(s);
  const seen: boolean[] = [];
  const unsub = new BlePlxAdapter(manager).onPowerChange(on => seen.push(on));
  expect(m.onStateChange).toHaveBeenCalledWith(expect.any(Function), true);
  const listener = m.onStateChange.mock.calls[0][0] as (s: string) => void;
  for (const st of ['PoweredOn', 'PoweredOff', 'Unauthorized', 'Resetting']) {
    listener(st);
  }
  expect(seen).toEqual([true, false, false, false]);
  unsub();
  expect(s.remove).toHaveBeenCalled();
});

test('knownDevice asks for connected devices with the board service', async () => {
  const {m, manager} = mockManager();
  const adapter = new BlePlxAdapter(manager);
  expect(await adapter.knownDevice(boardServiceUuid)).toBeNull();
  m.connectedDevices.mockResolvedValueOnce([device('AA', 23)]);
  const d = await adapter.knownDevice(boardServiceUuid);
  expect(d?.id).toBe('AA');
  expect(m.connectedDevices).toHaveBeenLastCalledWith([boardServiceUuid]);
});

test('scan filters by service, reports devices and errors, stops once', async () => {
  const {m, manager} = mockManager();
  const found: string[] = [];
  const errors: unknown[] = [];
  const stop = new BlePlxAdapter(manager).scan(
    boardServiceUuid,
    d => found.push(d.id),
    e => errors.push(e),
  );
  expect(m.startDeviceScan).toHaveBeenCalledWith([boardServiceUuid], null, expect.any(Function));
  const listener = m.startDeviceScan.mock.calls[0][2] as (e: unknown, d: Device | null) => void;
  listener(null, device('AA', 23));
  listener(new Error('scan failed'), null);
  stop();
  stop();
  listener(null, device('BB', 23));
  expect(found).toEqual(['AA']);
  expect(errors).toHaveLength(1);
  expect(m.stopDeviceScan).toHaveBeenCalledTimes(1);
});

test('a rejected startDeviceScan is reported as a scan error', async () => {
  const {m, manager} = mockManager();
  m.startDeviceScan.mockRejectedValueOnce(new Error('BluetoothUnauthorized'));
  const errors: unknown[] = [];
  new BlePlxAdapter(manager).scan(boardServiceUuid, () => {}, e => errors.push(e));
  await Promise.resolve();
  await Promise.resolve();
  expect(errors).toHaveLength(1);
});

test('device: connect negotiates the MTU, refreshes GATT, reports up and drops', async () => {
  const {m, manager} = mockManager();
  m.connectedDevices.mockResolvedValueOnce([device('AA', 0)]);
  const s = sub();
  m.onDeviceDisconnected.mockReturnValue(s);
  const d = (await new BlePlxAdapter(manager).knownDevice(boardServiceUuid))!;
  expect(d.maxWriteWithoutResponse).toBe(20); // unknown MTU → 23
  const ups: boolean[] = [];
  const unsub = d.onConnectionChange(up => ups.push(up));
  await d.connect();
  expect(m.connectToDevice).toHaveBeenCalledWith('AA', {
    requestMTU: requestedMtu,
    refreshGatt: 'OnConnected',
  });
  expect(d.maxWriteWithoutResponse).toBe(244);
  (m.onDeviceDisconnected.mock.calls[0][1] as () => void)();
  expect(ups).toEqual([true, false]);
  unsub();
  expect(s.remove).toHaveBeenCalled();
  await d.disconnect();
  expect(m.cancelDeviceConnection).toHaveBeenCalledWith('AA');
  expect(d.onServicesReset(() => {})).toEqual(expect.any(Function));
});

test('device: discover maps characteristics; a missing service is empty', async () => {
  const {m, manager} = mockManager();
  m.connectedDevices.mockResolvedValue([device('AA', 23)]);
  const d = (await new BlePlxAdapter(manager).knownDevice(boardServiceUuid))!;
  const chars = await d.discover(boardServiceUuid);
  expect([...chars.keys()]).toEqual([boardTextUuid.toLowerCase()]);
  expect(m.discoverAllServicesAndCharacteristicsForDevice).toHaveBeenCalledWith('AA');
  m.characteristicsForDevice.mockRejectedValueOnce(new Error('ServiceNotFound'));
  expect((await d.discover(boardServiceUuid)).size).toBe(0);
});

test('characteristic: writes base64 with or without response, reads, monitors', async () => {
  const {m, manager} = mockManager();
  m.connectedDevices.mockResolvedValue([device('AA', 23)]);
  const d = (await new BlePlxAdapter(manager).knownDevice(boardServiceUuid))!;
  const c = (await d.discover(boardServiceUuid)).get(boardTextUuid.toLowerCase())!;
  const id = boardTextUuid.toLowerCase();

  await c.write(Uint8Array.of(3, 2, 0x68, 0x69), true);
  expect(m.writeCharacteristicWithResponseForDevice).toHaveBeenCalledWith(
    'AA',
    boardServiceUuid,
    id,
    'AwJoaQ==',
  );
  await c.write(Uint8Array.of(0xff), false);
  expect(m.writeCharacteristicWithoutResponseForDevice).toHaveBeenCalledWith(
    'AA',
    boardServiceUuid,
    id,
    '/w==',
  );
  expect(Array.from(await c.read())).toEqual([1, 3, 0, 0, 0]);

  const s = sub();
  m.monitorCharacteristicForDevice.mockReturnValue(s);
  const values: number[][] = [];
  const stop = await c.subscribe(v => values.push(Array.from(v)));
  const listener = m.monitorCharacteristicForDevice.mock.calls[0][3] as (
    e: unknown,
    c: Characteristic | null,
  ) => void;
  listener(null, char(id, 'CQgH'));
  listener(new Error('disconnected'), null);
  listener(null, char(id, null));
  expect(values).toEqual([[9, 8, 7]]);
  stop();
  expect(s.remove).toHaveBeenCalled();
});

describe('requestBlePermissions', () => {
  function requester(result: string) {
    const r = {
      request: jest.fn(async () => result),
      requestMultiple: jest.fn(async (ps: string[]) =>
        Object.fromEntries(ps.map(p => [p, result])),
      ),
    };
    return {r, requester: r as unknown as PermissionRequester};
  }

  test('Android 12+ asks for BLUETOOTH_SCAN and BLUETOOTH_CONNECT', async () => {
    const {r, requester: q} = requester('granted');
    expect(await requestBlePermissions({OS: 'android', Version: 31}, q)).toBe(true);
    expect(r.requestMultiple).toHaveBeenCalledWith([
      'android.permission.BLUETOOTH_SCAN',
      'android.permission.BLUETOOTH_CONNECT',
    ]);
    expect(r.request).not.toHaveBeenCalled();
  });

  test('one denied permission on Android 12+ is a refusal', async () => {
    const {r, requester: q} = requester('granted');
    r.requestMultiple.mockResolvedValueOnce({
      'android.permission.BLUETOOTH_SCAN': 'granted',
      'android.permission.BLUETOOTH_CONNECT': 'never_ask_again',
    });
    expect(await requestBlePermissions({OS: 'android', Version: 34}, q)).toBe(false);
  });

  test('Android 10–11 ask for fine location', async () => {
    for (const v of [29, 30]) {
      const {r, requester: q} = requester('granted');
      expect(await requestBlePermissions({OS: 'android', Version: v}, q)).toBe(true);
      expect(r.request).toHaveBeenCalledWith('android.permission.ACCESS_FINE_LOCATION');
    }
    const {requester: denied} = requester('denied');
    expect(await requestBlePermissions({OS: 'android', Version: 29}, denied)).toBe(false);
  });

  test('not Android: nothing to ask', async () => {
    const {r, requester: q} = requester('denied');
    expect(await requestBlePermissions({OS: 'ios', Version: '26.0'}, q)).toBe(true);
    expect(r.request).not.toHaveBeenCalled();
    expect(r.requestMultiple).not.toHaveBeenCalled();
  });

  test('permission names per API level', () => {
    expect(blePermissionsFor(29)).toEqual(['android.permission.ACCESS_FINE_LOCATION']);
    expect(blePermissionsFor(35)).toEqual([
      'android.permission.BLUETOOTH_SCAN',
      'android.permission.BLUETOOTH_CONNECT',
    ]);
  });
});
