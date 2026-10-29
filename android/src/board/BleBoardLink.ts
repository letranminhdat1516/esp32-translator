// Port of app/lib/board/ble_board_link.dart: BoardLink over BLE (mirrors ios ESPLink). Finds (or
// reuses) the board, connects, reads board info, subscribes to audio and control, sets the clock,
// resends the label, switches the board mic on, keeps the link alive, and rescans after a drop.
import { BoardInfo, legacyBoardInfo } from '../core/model';
import { TypedEmitter } from '../engine/VoiceEngine';
import { BleAdapter, BleCharacteristic, BleDevice, Unsubscribe } from './BleAdapter';
import { BoardLink, BoardLinkEvents, BoardState } from './BoardLink';
import {
  TextKind,
  boardAudioUuid,
  boardControlUuid,
  boardInfoUuid,
  boardServiceUuid,
  boardTextUuid,
  frameText,
  labelText,
  parseBoardInfo,
  timeFrame,
} from './protocol';

export interface BleBoardLinkOptions {
  now?: () => Date;
  /**
   * Pause before rescanning after a drop or a failed connect/scan. Swift rescans at once; the
   * pause only keeps a failing connect from spinning. Doubles per consecutive failure.
   */
  retryDelayMs?: number;
  /** Ceiling of the backoff. */
  maxRetryDelayMs?: number;
  keepaliveIntervalMs?: number;
}

/** Runs a step whose errors are handled inside it (the Dart `unawaited`). */
function detach(step: Promise<void>): void {
  step.catch(() => {});
}

/** Longest wait for a disconnect before the retry starts anyway (a hung cancel must not block). */
export const disconnectTimeoutMs = 1000;

/** Control byte the board takes as "the app is alive" (0..2 are mic states). */
export const keepaliveByte = 0xff;

export class BleBoardLink implements BoardLink {
  private readonly now: () => Date;
  private readonly retryDelayMs: number;
  private readonly maxRetryDelayMs: number;
  private readonly keepaliveIntervalMs: number;
  private readonly events = new TypedEmitter<BoardLinkEvents>();

  private powerUnsub: Unsubscribe | null;
  private scanUnsub: Unsubscribe | null = null;
  private connUnsub: Unsubscribe | null = null;
  private resetUnsub: Unsubscribe | null = null;
  private notifyUnsubs: Unsubscribe[] = [];
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private keepaliveTimer: ReturnType<typeof setInterval> | null = null;

  private powered = false;
  private disposed = false;
  /** Consecutive failed attempts since the link was last ready (or Bluetooth came on). */
  private failures = 0;
  /** Bumped whenever the current attempt or GATT setup is abandoned; stale async steps stop. */
  private gen = 0;
  private device: BleDevice | null = null;
  private textChar: BleCharacteristic | null = null;
  private controlChar: BleCharacteristic | null = null;
  private ready = false;
  private labelSupported = false;
  private lastLabel: string | null = null;
  private state: BoardState = 'off';

  /** Chunks not yet written; a new text replaces them. */
  private pending: Uint8Array[] = [];
  private flushing: Promise<void> | null = null;

  info: BoardInfo = legacyBoardInfo;

  constructor(private readonly adapter: BleAdapter, options: BleBoardLinkOptions = {}) {
    this.now = options.now ?? (() => new Date());
    this.retryDelayMs = options.retryDelayMs ?? 500;
    this.maxRetryDelayMs = options.maxRetryDelayMs ?? 10_000;
    this.keepaliveIntervalMs = options.keepaliveIntervalMs ?? 20_000;
    this.powerUnsub = adapter.onPowerChange(on => this.onPower(on));
  }

  get currentState(): BoardState {
    return this.state;
  }

  on<K extends keyof BoardLinkEvents>(
    event: K,
    handler: (payload: BoardLinkEvents[K]) => void,
  ): Unsubscribe {
    return this.events.on(event, handler);
  }

  /** A subscriber's exception must never break the link's own state handling. */
  private emit<K extends keyof BoardLinkEvents>(event: K, payload: BoardLinkEvents[K]): void {
    if (this.disposed) {
      return;
    }
    try {
      this.events.emit(event, payload);
    } catch {
      // subscriber bug; the link carries on
    }
  }

  private setState(s: BoardState): void {
    if (this.disposed) {
      return;
    }
    this.state = s;
    this.emit('state', s);
  }

  private onPower(on: boolean): void {
    if (this.disposed) {
      return;
    }
    this.powered = on;
    if (on) {
      this.failures = 0;
      if (this.state === 'off') {
        detach(this.startScan());
      }
    } else {
      detach(this.abandon());
      this.setState('off');
    }
  }

  /**
   * Drops everything tied to the current link (not the Bluetooth power subscription). Resolves
   * when the disconnect has finished, or after `disconnectTimeoutMs`; never rejects.
   */
  private abandon(): Promise<void> {
    this.gen++;
    this.flushing = null;
    this.resetUnsub?.();
    this.resetUnsub = null;
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    this.stopKeepalive();
    this.scanUnsub?.();
    this.scanUnsub = null;
    this.connUnsub?.();
    this.connUnsub = null;
    this.dropGatt();
    const dev = this.device;
    this.device = null;
    if (!dev) {
      return Promise.resolve();
    }
    return new Promise<void>(resolve => {
      const timer = setTimeout(resolve, disconnectTimeoutMs);
      dev
        .disconnect()
        .catch(() => {})
        .then(() => {
          clearTimeout(timer);
          resolve();
        });
    });
  }

  /** Forgets the characteristics, their subscriptions and the queue (the connection may live on). */
  private dropGatt(): void {
    for (const unsub of this.notifyUnsubs) {
      unsub();
    }
    this.notifyUnsubs = [];
    this.pending = [];
    this.textChar = null;
    this.controlChar = null;
    this.ready = false;
  }

  private stopKeepalive(): void {
    if (this.keepaliveTimer !== null) {
      clearInterval(this.keepaliveTimer);
      this.keepaliveTimer = null;
    }
  }

  private scheduleRetry(): void {
    if (this.disposed || !this.powered) {
      return;
    }
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
    }
    // Failed connects and scans back off too, on purpose.
    let delay = this.retryDelayMs;
    for (let i = 0; i < this.failures && delay < this.maxRetryDelayMs; i++) {
      delay *= 2;
    }
    delay = Math.min(delay, this.maxRetryDelayMs);
    this.failures++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (!this.disposed && this.powered) {
        detach(this.startScan());
      }
    }, delay);
  }

  private async startScan(): Promise<void> {
    detach(this.abandon()); // normally nothing left: a retry follows a finished abandon
    const gen = this.gen;
    this.setState('scanning');
    try {
      const known = await this.adapter.knownDevice(boardServiceUuid);
      if (gen !== this.gen) {
        return;
      }
      if (known) {
        detach(this.connect(known, gen));
        return;
      }
      let found = false;
      let unsub: Unsubscribe | null = null;
      unsub = this.adapter.scan(
        boardServiceUuid,
        dev => {
          if (gen !== this.gen || found) {
            return;
          }
          found = true;
          if (unsub) {
            unsub();
            this.scanUnsub = null;
          }
          detach(this.connect(dev, gen));
        },
        () => {
          if (gen === this.gen) {
            this.scanUnsub?.();
            this.scanUnsub = null;
            this.scheduleRetry();
          }
        },
      );
      if (found) {
        unsub(); // a device was reported before scan() returned
      } else if (gen === this.gen) {
        this.scanUnsub = unsub;
      } else {
        unsub();
      }
    } catch {
      if (gen === this.gen) {
        this.scheduleRetry();
      }
    }
  }

  private async connect(dev: BleDevice, gen: number): Promise<void> {
    this.device = dev;
    this.setState('connecting');
    // Listen before connecting so a drop is never missed. The first `true` is the connect
    // itself; a `false` after it is a drop.
    let wasUp = false;
    this.connUnsub = dev.onConnectionChange(up => {
      // Not `gen`: a services reset bumps it but the connection lives on.
      if (dev !== this.device) {
        return;
      }
      if (up) {
        wasUp = true;
      } else if (wasUp) {
        this.onDrop();
      }
    });
    try {
      await dev.connect();
      if (gen !== this.gen) {
        return;
      }
      this.resetUnsub = dev.onServicesReset(() => detach(this.onServicesReset(dev)));
      await this.discoverAndSetUp(dev, gen);
    } catch {
      if (gen === this.gen) {
        this.onDrop();
      }
    }
  }

  private async discoverAndSetUp(dev: BleDevice, gen: number): Promise<void> {
    const chars = await dev.discover(boardServiceUuid);
    if (gen !== this.gen) {
      return;
    }
    await this.setUp(dev, chars, gen);
  }

  /**
   * The board changed its GATT table: the characteristics we hold are dead. Redo discovery and
   * setup on the same connection (time, label, mic).
   */
  private async onServicesReset(dev: BleDevice): Promise<void> {
    if (this.disposed || dev !== this.device) {
      return;
    }
    const gen = ++this.gen;
    this.stopKeepalive();
    this.dropGatt();
    this.flushing = null;
    this.setState('connecting');
    try {
      await this.discoverAndSetUp(dev, gen);
    } catch {
      if (gen === this.gen) {
        this.onDrop();
      }
    }
  }

  private onDrop(): void {
    const disconnected = this.abandon();
    if (this.disposed) {
      return;
    }
    this.setState(this.powered ? 'scanning' : 'off');
    // Retry only once the old connection is gone; anything that happened meanwhile (Bluetooth
    // off, dispose, a new attempt) bumped the generation and owns what comes next.
    const gen = this.gen;
    disconnected.then(() => {
      if (gen === this.gen) {
        this.scheduleRetry();
      }
    });
  }

  /** A notification failure on the current setup: reconnect rather than stay silently "ready". */
  private onNotifyError(gen: number): void {
    if (gen === this.gen && !this.disposed) {
      this.onDrop();
    }
  }

  private async setUp(
    dev: BleDevice,
    chars: Map<string, BleCharacteristic>,
    gen: number,
  ): Promise<void> {
    const text = chars.get(boardTextUuid.toLowerCase());
    const ctl = chars.get(boardControlUuid.toLowerCase());
    const aud = chars.get(boardAudioUuid.toLowerCase());
    if (!text || !ctl) {
      throw new Error('board GATT incomplete');
    }

    if (aud) {
      const unsub = await aud.subscribe(
        v => this.emit('audio', v),
        () => this.onNotifyError(gen),
      );
      if (gen !== this.gen) {
        unsub();
        return;
      }
      this.notifyUnsubs.push(unsub);
    }
    const ctlUnsub = await ctl.subscribe(
      v => {
        if (v.length > 0) {
          this.emit('control', { type: 'micChanged', on: v[0] !== 0 });
        }
      },
      () => this.onNotifyError(gen),
    );
    if (gen !== this.gen) {
      ctlUnsub();
      return;
    }
    this.notifyUnsubs.push(ctlUnsub);

    // Board info: absent on older firmware.
    const infoChar = chars.get(boardInfoUuid.toLowerCase());
    let parsed: BoardInfo | null = null;
    if (infoChar) {
      try {
        parsed = parseBoardInfo(await infoChar.read());
      } catch {
        parsed = null;
      }
      if (gen !== this.gen) {
        return;
      }
    }
    this.info = parsed ?? legacyBoardInfo;
    this.labelSupported = parsed !== null;

    this.textChar = text;
    this.controlChar = ctl;
    // Clock first (with response: never dropped or replaced by a subtitle), then the label the
    // board forgot, then the mic.
    await text.write(timeFrame(this.now()), true);
    if (gen !== this.gen) {
      return;
    }
    const label = this.lastLabel;
    if (this.labelSupported && label !== null) {
      for (const chunk of frameText(labelText(label), 'label', dev.maxWriteWithoutResponse)) {
        await text.write(chunk, true);
        if (gen !== this.gen) {
          return;
        }
      }
    }
    await ctl.write(Uint8Array.of(1), true);
    if (gen !== this.gen) {
      return;
    }
    // With response, so a dead link is noticed within one interval even without a drop event.
    this.keepaliveTimer = setInterval(() => {
      const c = this.controlChar;
      if (c && gen === this.gen) {
        c.write(Uint8Array.of(keepaliveByte), true).catch(() => {
          if (gen === this.gen && !this.disposed) {
            this.onDrop();
          }
        });
      }
    }, this.keepaliveIntervalMs);
    this.ready = true;
    this.failures = 0;
    this.setState('ready');
  }

  sendText(text: string, kind: TextKind): Promise<void> {
    if (this.disposed) {
      return Promise.resolve();
    }
    if (kind === 'label') {
      this.lastLabel = text;
      if (!this.labelSupported) {
        return Promise.resolve();
      }
    }
    const dev = this.device;
    if (!this.ready || !dev) {
      return Promise.resolve();
    }
    const shown = kind === 'label' ? labelText(text) : text;
    this.pending = frameText(shown, kind, dev.maxWriteWithoutResponse);
    return this.flush();
  }

  /**
   * Writes pending chunks one at a time; reads the queue afresh after each write, so a
   * replacement text takes over at the next chunk boundary. Everything is guarded by the
   * generation it started in: a stale flush (from before a drop or services reset) stops
   * writing, and its failure never clears the new link's queue or its `flushing` (Review Focus 1).
   */
  private flush(): Promise<void> {
    if (this.flushing) {
      return this.flushing;
    }
    const gen = this.gen;
    let finished = false;
    const run = (async () => {
      try {
        while (this.pending.length > 0 && gen === this.gen) {
          const c = this.textChar;
          if (!c) {
            break;
          }
          await c.write(this.pending.shift()!, false);
        }
      } catch {
        // Only this link's queue: a stale write may fail after a reset/reconnect.
        if (gen === this.gen) {
          this.pending = [];
        }
      } finally {
        finished = true;
        // A flush left over from an abandoned link must not clear a newer one.
        if (gen === this.gen) {
          this.flushing = null;
        }
      }
    })();
    // A flush that ended without awaiting has already cleared `flushing`; do not pin it.
    if (!finished) {
      this.flushing = run;
    }
    return run;
  }

  async setBoardMic(on: boolean): Promise<void> {
    const c = this.controlChar;
    if (!this.ready || !c) {
      return;
    }
    try {
      await c.write(Uint8Array.of(on ? 1 : 0), true);
    } catch {
      // the next drop/reconnect sets the mic again
    }
  }

  /** Stops scanning, disconnects and drops every subscriber. Idempotent. */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    detach(this.abandon());
    this.disposed = true;
    this.powerUnsub?.();
    this.powerUnsub = null;
    this.events.removeAll();
  }
}
