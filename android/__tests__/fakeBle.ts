// Scripted BleAdapter for the BleBoardLink tests: the TypeScript twin of the fakes at the top of
// app/test/board/ble_board_link_test.dart. Not a suite (jest only runs *.test.*).
import { BleAdapter, BleCharacteristic, BleDevice, Unsubscribe } from '../src/board/BleAdapter';
import {
  boardAudioUuid,
  boardControlUuid,
  boardInfoUuid,
  boardTextUuid,
} from '../src/board/protocol';

export interface Write {
  uuid: string;
  data: Uint8Array;
  withResponse: boolean;
}

/** A promise with its settle functions exposed (Dart's Completer). */
export class Deferred {
  readonly promise: Promise<void>;
  resolve!: () => void;
  reject!: (error: unknown) => void;
  constructor() {
    this.promise = new Promise<void>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

class Listeners<T> {
  private readonly set = new Set<(value: T) => void>();
  add(listener: (value: T) => void): Unsubscribe {
    this.set.add(listener);
    return () => {
      this.set.delete(listener);
    };
  }
  emit(value: T): void {
    for (const l of [...this.set]) {
      l(value);
    }
  }
  get size(): number {
    return this.set.size;
  }
}

export class FakeChar implements BleCharacteristic {
  /** While set, writes without response wait for it (captured at call time). */
  gate: Deferred | null = null;
  /** When set, writes with response fail with it. */
  failWithResponse: Error | null = null;
  private readonly listeners = new Listeners<Uint8Array>();
  private readonly errorListeners = new Listeners<unknown>();
  /** Every error callback ever passed to subscribe (to replay a late, stale error). */
  readonly errorCallbacks: Array<(error: unknown) => void> = [];

  constructor(
    readonly uuid: string,
    private readonly dev: FakeDevice,
    public readValue?: Uint8Array,
  ) {}

  async write(data: Uint8Array, withResponse: boolean): Promise<void> {
    const gate = this.gate;
    if (!withResponse && gate) {
      await gate.promise;
    }
    if (withResponse && this.failWithResponse) {
      throw this.failWithResponse;
    }
    this.dev.writes.push({ uuid: this.uuid, data, withResponse });
  }

  async read(): Promise<Uint8Array> {
    if (!this.readValue) {
      throw new Error('not readable');
    }
    return this.readValue;
  }

  async subscribe(
    onValue: (value: Uint8Array) => void,
    onError: (error: unknown) => void,
  ): Promise<Unsubscribe> {
    const offValue = this.listeners.add(onValue);
    const offError = this.errorListeners.add(onError);
    this.errorCallbacks.push(onError);
    return () => {
      offValue();
      offError();
    };
  }

  /** Reports a notification failure (e.g. the CCCD enable failed) to every subscriber. */
  failNotify(error: unknown): void {
    this.errorListeners.emit(error);
  }

  /** Delivers a notification to every subscriber. */
  notify(value: Uint8Array): void {
    this.listeners.emit(value);
  }

  get subscribers(): number {
    return this.listeners.size;
  }
}

export class FakeDevice implements BleDevice {
  readonly id = 'fake';
  readonly chars = new Map<string, FakeChar>();
  readonly writes: Write[] = [];
  connectCalls = 0;
  discoverCalls = 0;
  disconnectCalls = 0;
  failNextConnect = false;
  /** While > 0, discovery returns no characteristics (and counts down). */
  incompleteDiscoveries = 0;
  /** When set, connect() waits for it (to act while connecting). */
  connectGate: Deferred | null = null;
  /** When set, disconnect() waits for it (a never-settled one models a hung cancel). */
  disconnectGate: Deferred | null = null;
  private readonly conn = new Listeners<boolean>();
  private readonly reset = new Listeners<void>();

  constructor(readonly maxWriteWithoutResponse = 20, info?: Uint8Array) {
    for (const uuid of [boardAudioUuid, boardTextUuid, boardControlUuid]) {
      this.chars.set(uuid.toLowerCase(), new FakeChar(uuid, this));
    }
    if (info) {
      this.chars.set(boardInfoUuid.toLowerCase(), new FakeChar(boardInfoUuid, this, info));
    }
  }

  get text(): FakeChar {
    return this.chars.get(boardTextUuid.toLowerCase())!;
  }
  get audio(): FakeChar {
    return this.chars.get(boardAudioUuid.toLowerCase())!;
  }
  get control(): FakeChar {
    return this.chars.get(boardControlUuid.toLowerCase())!;
  }
  get textWrites(): Write[] {
    return this.writes.filter(w => w.uuid === boardTextUuid);
  }
  get controlWrites(): Write[] {
    return this.writes.filter(w => w.uuid === boardControlUuid);
  }
  get connectionListeners(): number {
    return this.conn.size;
  }

  drop(): void {
    this.conn.emit(false);
  }
  fireServicesReset(): void {
    this.reset.emit();
  }

  onConnectionChange(listener: (connected: boolean) => void): Unsubscribe {
    return this.conn.add(listener);
  }
  onServicesReset(listener: () => void): Unsubscribe {
    return this.reset.add(listener);
  }

  async connect(): Promise<void> {
    this.connectCalls++;
    if (this.connectGate) {
      await this.connectGate.promise;
    }
    if (this.failNextConnect) {
      this.failNextConnect = false;
      throw new Error('connect failed');
    }
    this.conn.emit(true);
  }

  async disconnect(): Promise<void> {
    this.disconnectCalls++;
    if (this.disconnectGate) {
      await this.disconnectGate.promise;
    }
  }

  async discover(_serviceUuid: string): Promise<Map<string, BleCharacteristic>> {
    this.discoverCalls++;
    if (this.incompleteDiscoveries > 0) {
      this.incompleteDiscoveries--;
      return new Map();
    }
    return new Map(this.chars);
  }
}

export class FakeAdapter implements BleAdapter {
  known: FakeDevice | null = null;
  readonly scanned: FakeDevice[] = [];
  scans = 0;
  scanCancels = 0;
  /** When set, the next scan reports this error instead of devices. */
  scanError: Error | null = null;
  private readonly powerListeners = new Listeners<boolean>();

  onPowerChange(listener: (on: boolean) => void): Unsubscribe {
    return this.powerListeners.add(listener);
  }

  get powerSubscribers(): number {
    return this.powerListeners.size;
  }

  power(on: boolean): void {
    this.powerListeners.emit(on);
  }

  async knownDevice(_serviceUuid: string): Promise<BleDevice | null> {
    return this.known;
  }

  scan(
    _serviceUuid: string,
    onDevice: (device: BleDevice) => void,
    onError: (error: unknown) => void,
  ): Unsubscribe {
    this.scans++;
    let active = true;
    const error = this.scanError;
    this.scanError = null;
    // Like a real scan (and the Dart stream), results arrive after scan() returned.
    Promise.resolve().then(() => {
      if (error) {
        if (active) {
          onError(error);
        }
        return;
      }
      for (const d of this.scanned) {
        if (active) {
          onDevice(d);
        }
      }
    });
    return () => {
      if (active) {
        active = false;
        this.scanCancels++;
      }
    };
  }
}

export function infoBytes(version: number, sets: number): Uint8Array {
  /* eslint-disable no-bitwise -- little-endian u32 */
  return Uint8Array.of(
    version,
    sets & 0xff,
    (sets >> 8) & 0xff,
    (sets >> 16) & 0xff,
    (sets >> 24) & 0xff,
  );
  /* eslint-enable no-bitwise */
}

/** Payload text of a frame (bytes after `[flags][kind]`). */
export function payloadOf(w: Write): string {
  return Buffer.from(w.data.subarray(2)).toString('utf8');
}
