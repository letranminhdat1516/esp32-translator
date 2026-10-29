// Port of app/lib/board/ble_adapter.dart: the few Bluetooth calls BleBoardLink needs, so tests can
// script them (__tests__/fakeBle.ts), plus BlePlxAdapter on react-native-ble-plx 3.5 and the
// Android runtime-permission request.
//
// What react-native-ble-plx offers and does not offer here:
// - Power: `onStateChange(listener, true)` (current state first). Anything but `PoweredOn`
//   (Unauthorized, Resetting, PoweredOff…) counts as off.
// - Already connected board: `connectedDevices([service])`. Unlike Dart's `systemDevices` it lists
//   only connections this BleManager made, so it is empty after an app restart (we then scan).
// - Scan filtered by the service UUID: `startDeviceScan`; one scan per manager at a time.
// - Connect: `connectToDevice(id, {requestMTU: 517, refreshGatt: 'OnConnected'})`. The MTU is
//   negotiated during connect (Android 14+ always negotiates 517 itself); the write-without-response
//   limit is `device.mtu - 3`. On Android ble-plx first cancels a link the phone already holds to
//   that device; the disconnect it causes arrives before `connected = true` and is ignored by the
//   link (only a drop after an up counts).
// - Drop: `onDeviceDisconnected(id, …)`.
// - Notifications: `monitorCharacteristicForDevice` returns at once; enabling the CCCD is not
//   awaitable and its failure arrives as an error on the listener. Errors go to the subscriber's
//   `onError`; BleBoardLink then reconnects instead of staying "ready" with a silent board.
// - Values cross the bridge as base64 strings (encoded/decoded here).
// - **No Services Changed event.** ble-plx (RxAndroidBle underneath) does not expose
//   `BluetoothGattCallback.onServiceChanged`, so `onServicesReset` never fires in BlePlxAdapter.
//   Instead every connect refreshes Android's GATT cache (`refreshGatt: 'OnConnected'`), so a
//   reflashed board (which reboots, i.e. drops and is reconnected) is always seen with its new
//   table. The link still handles `onServicesReset` (re-discovery on the same connection) so an
//   adapter that can see the event only has to fire it.
import { PermissionsAndroid, Platform } from 'react-native';
import type { BleManager, Device, Subscription } from 'react-native-ble-plx';

export type Unsubscribe = () => void;

/** One GATT characteristic of a connected board. */
export interface BleCharacteristic {
  /**
   * Write with or without response. Without response resolves once the stack has accepted the
   * packet (the adapter paces itself).
   */
  write(data: Uint8Array, withResponse: boolean): Promise<void>;

  read(): Promise<Uint8Array>;

  /**
   * Enables notifications; resolves with the function that stops them. `onError` is called when
   * notifications fail (enable refused, link lost); no values follow it.
   */
  subscribe(
    onValue: (value: Uint8Array) => void,
    onError: (error: unknown) => void,
  ): Promise<Unsubscribe>;
}

/** A peripheral found by a BleAdapter. */
export interface BleDevice {
  readonly id: string;

  /** Called with true when a connect completes and with false on every drop. */
  onConnectionChange(listener: (connected: boolean) => void): Unsubscribe;

  /**
   * Called when the peripheral changed its GATT table (Services Changed); the old
   * characteristics are then invalid. Never fires in BlePlxAdapter (see the file header).
   */
  onServicesReset(listener: () => void): Unsubscribe;

  connect(): Promise<void>;
  disconnect(): Promise<void>;

  /** Characteristics of `serviceUuid` keyed by lower-case UUID; empty when the service is missing. */
  discover(serviceUuid: string): Promise<Map<string, BleCharacteristic>>;

  /** Largest write-without-response payload (ATT MTU - 3). */
  readonly maxWriteWithoutResponse: number;
}

/** The few Bluetooth calls BleBoardLink needs. */
export interface BleAdapter {
  /** Bluetooth radio on/off; the current state is reported first when known. */
  onPowerChange(listener: (on: boolean) => void): Unsubscribe;

  /** An already connected (system) device with `serviceUuid`, if any. */
  knownDevice(serviceUuid: string): Promise<BleDevice | null>;

  /** Scans for devices advertising `serviceUuid` until the returned function is called. */
  scan(
    serviceUuid: string,
    onDevice: (device: BleDevice) => void,
    onError: (error: unknown) => void,
  ): Unsubscribe;
}

// --- base64 (ble-plx values) ------------------------------------------------

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/* eslint-disable no-bitwise -- base64 packs 6-bit groups */
export function toBase64(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i += 3) {
    const n = (data[i] << 16) | ((data[i + 1] ?? 0) << 8) | (data[i + 2] ?? 0);
    out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63];
    out += i + 1 < data.length ? alphabet[(n >> 6) & 63] : '=';
    out += i + 2 < data.length ? alphabet[n & 63] : '=';
  }
  return out;
}

/** Base64 character code → 6-bit value; -1 for anything else (padding, whitespace). */
const decodeTable = (() => {
  const table = new Int8Array(128).fill(-1);
  for (let i = 0; i < alphabet.length; i++) {
    table[alphabet.charCodeAt(i)] = i;
  }
  return table;
})();

export function fromBase64(text: string): Uint8Array {
  const out = new Uint8Array(Math.floor((text.length * 3) / 4));
  let bits = 0;
  let acc = 0;
  let j = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    const v = code < 128 ? decodeTable[code] : -1;
    if (v < 0) {
      continue;
    }
    acc = ((acc << 6) | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[j++] = (acc >> bits) & 0xff;
    }
  }
  return out.subarray(0, j);
}
/* eslint-enable no-bitwise */

// --- react-native-ble-plx ---------------------------------------------------

/** The part of BleManager BlePlxAdapter uses (a mock in tests implements just this). */
export type PlxManager = Pick<
  BleManager,
  | 'onStateChange'
  | 'connectedDevices'
  | 'startDeviceScan'
  | 'stopDeviceScan'
  | 'connectToDevice'
  | 'cancelDeviceConnection'
  | 'onDeviceDisconnected'
  | 'discoverAllServicesAndCharacteristicsForDevice'
  | 'characteristicsForDevice'
  | 'readCharacteristicForDevice'
  | 'writeCharacteristicWithResponseForDevice'
  | 'writeCharacteristicWithoutResponseForDevice'
  | 'monitorCharacteristicForDevice'
>;

/** ATT MTU asked for at connect (the board's ESP32 accepts up to 517). */
export const requestedMtu = 517;
const defaultMtu = 23;

/** BleAdapter on react-native-ble-plx: `new BlePlxAdapter(new BleManager())`. */
export class BlePlxAdapter implements BleAdapter {
  constructor(private readonly manager: PlxManager) {}

  onPowerChange(listener: (on: boolean) => void): Unsubscribe {
    const sub = this.manager.onStateChange(s => listener(s === 'PoweredOn'), true);
    return () => sub.remove();
  }

  async knownDevice(serviceUuid: string): Promise<BleDevice | null> {
    const devices = await this.manager.connectedDevices([serviceUuid]);
    return devices.length === 0 ? null : new PlxDevice(this.manager, devices[0]);
  }

  scan(
    serviceUuid: string,
    onDevice: (device: BleDevice) => void,
    onError: (error: unknown) => void,
  ): Unsubscribe {
    let active = true;
    this.manager
      .startDeviceScan([serviceUuid], null, (error, device) => {
        if (!active) {
          return;
        }
        if (error) {
          onError(error);
        } else if (device) {
          onDevice(new PlxDevice(this.manager, device));
        }
      })
      .catch(error => {
        if (active) {
          onError(error);
        }
      });
    return () => {
      if (!active) {
        return;
      }
      active = false;
      this.manager.stopDeviceScan().catch(() => {});
    };
  }
}

class PlxDevice implements BleDevice {
  readonly id: string;
  private mtu: number;
  private readonly upListeners = new Set<(connected: boolean) => void>();

  constructor(private readonly manager: PlxManager, device: Device) {
    this.id = device.id;
    this.mtu = device.mtu || defaultMtu;
  }

  get maxWriteWithoutResponse(): number {
    return this.mtu - 3;
  }

  onConnectionChange(listener: (connected: boolean) => void): Unsubscribe {
    this.upListeners.add(listener);
    const sub: Subscription = this.manager.onDeviceDisconnected(this.id, () => listener(false));
    return () => {
      this.upListeners.delete(listener);
      sub.remove();
    };
  }

  onServicesReset(_listener: () => void): Unsubscribe {
    return () => {};
  }

  async connect(): Promise<void> {
    const device = await this.manager.connectToDevice(this.id, {
      requestMTU: requestedMtu,
      refreshGatt: 'OnConnected',
    });
    this.mtu = device.mtu || defaultMtu;
    for (const l of [...this.upListeners]) {
      l(true);
    }
  }

  async disconnect(): Promise<void> {
    await this.manager.cancelDeviceConnection(this.id);
  }

  async discover(serviceUuid: string): Promise<Map<string, BleCharacteristic>> {
    await this.manager.discoverAllServicesAndCharacteristicsForDevice(this.id);
    const out = new Map<string, BleCharacteristic>();
    let chars;
    try {
      chars = await this.manager.characteristicsForDevice(this.id, serviceUuid);
    } catch {
      return out; // service missing
    }
    for (const c of chars) {
      out.set(
        c.uuid.toLowerCase(),
        new PlxCharacteristic(this.manager, this.id, serviceUuid, c.uuid),
      );
    }
    return out;
  }
}

class PlxCharacteristic implements BleCharacteristic {
  constructor(
    private readonly manager: PlxManager,
    private readonly deviceId: string,
    private readonly serviceUuid: string,
    private readonly uuid: string,
  ) {}

  async write(data: Uint8Array, withResponse: boolean): Promise<void> {
    const value = toBase64(data);
    if (withResponse) {
      await this.manager.writeCharacteristicWithResponseForDevice(
        this.deviceId,
        this.serviceUuid,
        this.uuid,
        value,
      );
    } else {
      await this.manager.writeCharacteristicWithoutResponseForDevice(
        this.deviceId,
        this.serviceUuid,
        this.uuid,
        value,
      );
    }
  }

  async read(): Promise<Uint8Array> {
    const c = await this.manager.readCharacteristicForDevice(
      this.deviceId,
      this.serviceUuid,
      this.uuid,
    );
    return fromBase64(c.value ?? '');
  }

  async subscribe(
    onValue: (value: Uint8Array) => void,
    onError: (error: unknown) => void,
  ): Promise<Unsubscribe> {
    const sub = this.manager.monitorCharacteristicForDevice(
      this.deviceId,
      this.serviceUuid,
      this.uuid,
      (error, c) => {
        // Errors: a CCCD failure or the drop (the link ignores the latter once it has abandoned).
        if (error) {
          onError(error);
        } else if (c?.value) {
          onValue(fromBase64(c.value));
        }
      },
    );
    return () => sub.remove();
  }
}

// --- Android runtime permissions ---------------------------------------------

type Permission = Parameters<typeof PermissionsAndroid.request>[0];

/** The PermissionsAndroid calls requestBlePermissions makes (injectable for tests). */
export interface PermissionRequester {
  request(permission: Permission): Promise<string>;
  requestMultiple(permissions: Permission[]): Promise<Partial<Record<Permission, string>>>;
}

/** Runtime permissions Bluetooth needs on Android `apiLevel`. */
export function blePermissionsFor(apiLevel: number): Permission[] {
  return apiLevel >= 31
    ? ['android.permission.BLUETOOTH_SCAN', 'android.permission.BLUETOOTH_CONNECT']
    : ['android.permission.ACCESS_FINE_LOCATION'];
}

/**
 * Asks for the runtime permissions scanning and connecting need; true when all are granted.
 *
 * - Android 12+ (API 31+): `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` (the "Nearby devices" prompt).
 * - Android 10–11 (API 29–30, minSdk is 29): `ACCESS_FINE_LOCATION` (BLE scan results need it).
 * - Other platforms: nothing to ask, true.
 *
 * The manifest (track T4) must declare `BLUETOOTH_SCAN` (`android:usesPermissionFlags=
 * "neverForLocation"`), `BLUETOOTH_CONNECT`, and for API ≤ 30 `BLUETOOTH`, `BLUETOOTH_ADMIN` and
 * `ACCESS_FINE_LOCATION` with `android:maxSdkVersion="30"`; a permission missing from the manifest
 * is reported denied without a prompt. API 29–30 also need Location switched on in system
 * settings for scans to return anything (not a permission: the scan just stays empty).
 */
export async function requestBlePermissions(
  platform: { OS: string; Version: number | string } = Platform,
  permissions: PermissionRequester = PermissionsAndroid,
): Promise<boolean> {
  if (platform.OS !== 'android') {
    return true;
  }
  const wanted = blePermissionsFor(Number(platform.Version));
  if (wanted.length === 1) {
    return (await permissions.request(wanted[0])) === 'granted';
  }
  const results = await permissions.requestMultiple(wanted);
  return wanted.every(p => results[p] === 'granted');
}
