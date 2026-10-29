// Port of app/test/board/ble_board_link_test.dart (every case, same names), plus the gaps the
// Track F review listed (dispose, power-off while connecting, label before ready) and Review
// Focus 1 (a stale write failing after a reset/reconnect never clears the new queue).
import { BleBoardLink } from '../src/board/BleBoardLink';
import { BoardControl, BoardState } from '../src/board/BoardLink';
import { frameText, parseBoardInfo, timeFrame } from '../src/board/protocol';
import { FontSets, boardInfoEquals, legacyBoardInfo } from '../src/core/model';
import { Deferred, FakeAdapter, FakeDevice, infoBytes, payloadOf } from './fakeBle';

const clock = new Date(Date.UTC(2026, 0, 2, 3, 4, 5));

/** One macrotask turn: every pending promise chain and 0 ms timer runs. */
const settle = () => new Promise<void>(resolve => setTimeout(resolve, 0));

async function until(ok: () => boolean): Promise<void> {
  for (let i = 0; i < 200 && !ok(); i++) {
    await settle();
  }
  if (!ok()) {
    throw new Error('condition not reached');
  }
}

const bytes = (frames: Uint8Array[]) => frames.map(f => Array.from(f));
const kinds = (dev: FakeDevice) => dev.textWrites.map(w => w.data[1]);

let adapter: FakeAdapter;
let link: BleBoardLink;
let states: BoardState[];

function makeLink(options: ConstructorParameters<typeof BleBoardLink>[1] = {}): BleBoardLink {
  link = new BleBoardLink(adapter, options);
  states = [];
  link.on('state', s => states.push(s));
  return link;
}

async function start(dev: FakeDevice, viaScan = true): Promise<void> {
  if (viaScan) {
    adapter.scanned.push(dev);
  } else {
    adapter.known = dev;
  }
  makeLink({ retryDelayMs: 0, now: () => clock });
  adapter.power(true);
  await until(() => states.includes('ready'));
}

const lastIsReady = () => states.length > 0 && states[states.length - 1] === 'ready';

beforeEach(() => {
  adapter = new FakeAdapter();
});

afterEach(() => {
  link?.dispose();
  jest.useRealTimers();
});

test('scans, connects, sets the clock with response, then mic on', async () => {
  const dev = new FakeDevice(100, infoBytes(1, 0x3));
  await start(dev);
  expect(states).toEqual(['scanning', 'connecting', 'ready']);
  expect(link.currentState).toBe('ready');
  expect(adapter.scanCancels).toBe(1);
  expect(dev.textWrites).toHaveLength(1);
  const t = dev.textWrites[0];
  expect(t.withResponse).toBe(true);
  expect(Array.from(t.data)).toEqual(Array.from(timeFrame(clock)));
  expect(dev.controlWrites).toHaveLength(1);
  const c = dev.controlWrites[0];
  expect(Array.from(c.data)).toEqual([1]);
  expect(c.withResponse).toBe(true);
});

test('uses an already connected system device without scanning', async () => {
  await start(new FakeDevice(), false);
  expect(adapter.scans).toBe(0);
});

test('info is read from 0005; defaults when absent', async () => {
  await start(new FakeDevice(20, infoBytes(1, 0x3)));
  expect(boardInfoEquals(link.info, parseBoardInfo(infoBytes(1, 0x3))!)).toBe(true);
  expect(link.info.protocolVersion).toBe(1);

  link.dispose();
  adapter = new FakeAdapter();
  await start(new FakeDevice());
  expect(boardInfoEquals(link.info, { protocolVersion: 0, fontSets: FontSets.latinVI })).toBe(true);
});

test('an unreadable or short 0005 counts as legacy: no label', async () => {
  const dev = new FakeDevice(100, Uint8Array.of(1, 2));
  await start(dev);
  expect(link.info).toBe(legacyBoardInfo);
  dev.writes.length = 0;
  await link.sendText('Chủ tịch', 'label');
  expect(dev.textWrites).toEqual([]);
});

test('audio is raw; control notify becomes mic events', async () => {
  const dev = new FakeDevice();
  await start(dev);
  const audio: Uint8Array[] = [];
  const ctl: BoardControl[] = [];
  link.on('audio', a => audio.push(a));
  link.on('control', c => ctl.push(c));
  dev.audio.notify(Uint8Array.of(9, 8, 7));
  dev.control.notify(Uint8Array.of(1));
  dev.control.notify(Uint8Array.of(0));
  dev.control.notify(new Uint8Array(0));
  await settle();
  expect(audio.map(a => Array.from(a))).toEqual([[9, 8, 7]]);
  expect(ctl).toEqual([
    { type: 'micChanged', on: true },
    { type: 'micChanged', on: false },
  ]);
});

test('sendText frames by MTU and writes without response in order', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  dev.writes.length = 0;
  await link.sendText('a'.repeat(40), 'subtitle');
  const w = dev.textWrites;
  expect(w).toHaveLength(3);
  expect(w.every(x => !x.withResponse)).toBe(true);
  expect(bytes(w.map(x => x.data))).toEqual(bytes(frameText('a'.repeat(40), 'subtitle', 20)));
});

test('a new text replaces unsent chunks of the previous one', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  dev.writes.length = 0;
  const gate = (dev.text.gate = new Deferred());
  const first = link.sendText('a'.repeat(40), 'subtitle');
  await settle();
  const second = link.sendText('bbb', 'subtitle');
  gate.resolve();
  await first;
  await second;
  const w = dev.textWrites;
  // chunk 1 of the old text was already in flight; the rest is dropped
  expect(payloadOf(w[0])).toBe('a'.repeat(18));
  expect(w).toHaveLength(2);
  expect(Array.from(w[1].data)).toEqual(Array.from(frameText('bbb', 'subtitle', 20)[0]));
});

test('sendText and setBoardMic before ready do nothing', async () => {
  makeLink({ retryDelayMs: 0 });
  await link.sendText('x', 'subtitle');
  await link.setBoardMic(true);
  expect(adapter.scans).toBe(0);
  expect(link.currentState).toBe('off');
});

test('label is sent only when 0005 exists', async () => {
  const old = new FakeDevice();
  await start(old);
  old.writes.length = 0;
  await link.sendText('Chủ tịch', 'label');
  expect(old.textWrites).toEqual([]);

  link.dispose();
  adapter = new FakeAdapter();
  const neu = new FakeDevice(100, infoBytes(1, 0x3));
  await start(neu);
  neu.writes.length = 0;
  await link.sendText('x'.repeat(40), 'label');
  expect(neu.textWrites).toHaveLength(1);
  const w = neu.textWrites[0];
  expect(w.data[1]).toBe(3);
  expect(payloadOf(w)).toHaveLength(32);
});

test('a label set before ready goes out on ready, after the clock', async () => {
  const dev = new FakeDevice(100, infoBytes(1, 0x3));
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 0, now: () => clock });
  await link.sendText('Chủ tịch', 'label');
  expect(dev.writes).toEqual([]);
  adapter.power(true);
  await until(() => states.includes('ready'));
  expect(kinds(dev)).toEqual([2, 3]);
  expect(payloadOf(dev.textWrites[1])).toBe('Chủ tịch');
  expect(dev.textWrites.every(w => w.withResponse)).toBe(true);
});

test('setBoardMic writes [1]/[0] with response', async () => {
  const dev = new FakeDevice();
  await start(dev);
  dev.writes.length = 0;
  await link.setBoardMic(false);
  await link.setBoardMic(true);
  expect(bytes(dev.controlWrites.map(w => w.data))).toEqual([[0], [1]]);
  expect(dev.controlWrites.every(w => w.withResponse)).toBe(true);
});

test('drop: reconnects, resends time and label, next subtitle goes out', async () => {
  const dev = new FakeDevice(100, infoBytes(1, 0x3));
  await start(dev);
  await link.sendText('Chủ tịch', 'label');
  dev.writes.length = 0;
  states.length = 0;

  dev.drop();
  await until(lastIsReady);
  expect(states[0]).toBe('scanning');
  expect(dev.connectCalls).toBe(2);

  expect(kinds(dev)).toEqual([2, 3]);
  expect(dev.textWrites.every(w => w.withResponse)).toBe(true);
  expect(payloadOf(dev.textWrites[1])).toBe('Chủ tịch');

  dev.writes.length = 0;
  await link.sendText('xin chào', 'subtitle');
  expect(dev.textWrites).toHaveLength(1);
  expect(dev.textWrites[0].data[1]).toBe(0);
  expect(payloadOf(dev.textWrites[0])).toBe('xin chào');
});

test('drop on old firmware resends time but no label', async () => {
  const dev = new FakeDevice();
  await start(dev);
  await link.sendText('label', 'label');
  dev.writes.length = 0;
  states.length = 0;
  dev.drop();
  await until(lastIsReady);
  expect(kinds(dev)).toEqual([2]);
});

test('chunks pending at a drop are discarded', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  const gate = (dev.text.gate = new Deferred());
  const f = link.sendText('a'.repeat(60), 'subtitle');
  await settle();
  states.length = 0;
  dev.drop();
  dev.text.gate = null;
  gate.resolve();
  await f;
  await until(lastIsReady);
  // the in-flight chunk lands; nothing else of the old text, then only the clock
  const ws = dev.textWrites;
  expect(ws.filter(w => w.data[1] === 0)).toHaveLength(1);
  expect(ws[ws.length - 1].data[1]).toBe(2);
});

test('a failed connect is retried', async () => {
  const dev = new FakeDevice();
  dev.failNextConnect = true;
  await start(dev);
  expect(dev.connectCalls).toBe(2);
});

test('a failed scan is retried', async () => {
  adapter.scanError = new Error('scan failed');
  await start(new FakeDevice());
  expect(adapter.scans).toBe(2);
});

test('Bluetooth off goes to off; back on connects again', async () => {
  const dev = new FakeDevice();
  await start(dev);
  states.length = 0;
  adapter.power(false);
  await until(() => states.includes('off'));
  expect(link.currentState).toBe('off');
  adapter.power(true);
  await until(() => states.includes('ready'));
  expect(dev.connectCalls).toBe(2);
});

test('Bluetooth off while connecting: the late connect is ignored', async () => {
  const dev = new FakeDevice();
  const gate = (dev.connectGate = new Deferred());
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 0 });
  adapter.power(true);
  await until(() => states.includes('connecting'));
  adapter.power(false);
  gate.resolve();
  for (let i = 0; i < 10; i++) {
    await settle();
  }
  expect(states).toEqual(['scanning', 'connecting', 'off']);
  expect(dev.discoverCalls).toBe(0);
  expect(dev.writes).toEqual([]);
});

test('keepalive 0xFF on the control characteristic', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 0 });
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  expect(link.currentState).toBe('ready');
  dev.writes.length = 0;
  await jest.advanceTimersByTimeAsync(41_000);
  expect(bytes(dev.controlWrites.map(w => w.data))).toEqual([[0xff], [0xff]]);
  expect(dev.controlWrites.every(w => w.withResponse)).toBe(true);
});

test('keepalive stops when the link drops', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 1_000_000, maxRetryDelayMs: 1_000_000 });
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  dev.drop();
  dev.writes.length = 0;
  await jest.advanceTimersByTimeAsync(60_000);
  expect(dev.controlWrites).toEqual([]);
});

test('services reset: rediscovers, resubscribes, resends time and label', async () => {
  const dev = new FakeDevice(100, infoBytes(1, 0x3));
  await start(dev);
  await link.sendText('Chủ tịch', 'label');
  dev.writes.length = 0;
  const audio: Uint8Array[] = [];
  link.on('audio', a => audio.push(a));
  states.length = 0;

  dev.fireServicesReset();
  await until(lastIsReady);
  expect(dev.discoverCalls).toBe(2);
  expect(dev.connectCalls).toBe(1);
  expect(kinds(dev)).toEqual([2, 3]);
  expect(payloadOf(dev.textWrites[1])).toBe('Chủ tịch');
  expect(bytes(dev.controlWrites.map(w => w.data))).toEqual([[1]]);

  // old subscriptions are gone: one notification yields one event
  dev.audio.notify(Uint8Array.of(5));
  await settle();
  expect(audio).toHaveLength(1);
  expect(dev.audio.subscribers).toBe(1);

  dev.writes.length = 0;
  await link.sendText('xin chào', 'subtitle');
  expect(dev.textWrites).toHaveLength(1);
  expect(payloadOf(dev.textWrites[0])).toBe('xin chào');
});

test('a stale flush from before a reconnect does not strand the next text', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  const gate = (dev.text.gate = new Deferred());
  const stale = link.sendText('a'.repeat(60), 'subtitle');
  await settle();
  states.length = 0;
  dev.drop();
  dev.text.gate = null; // the old write stays stuck on its own gate
  await until(lastIsReady);
  dev.writes.length = 0;
  let done = false;
  const sent = link.sendText('xin chào', 'subtitle').then(() => {
    done = true;
  });
  await until(() => done);
  await sent;
  expect(dev.textWrites).toHaveLength(1);
  expect(payloadOf(dev.textWrites[0])).toBe('xin chào');
  gate.resolve();
  await stale;
});

test('incomplete GATT discovery retries with growing delays, max 10 s', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  dev.incompleteDiscoveries = 100;
  adapter.scanned.push(dev);
  makeLink();
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  expect(dev.connectCalls).toBe(1);
  // delays: 0.5, 1, 2, 4, 8, 10, 10 s
  let calls = 1;
  for (const d of [500, 1000, 2000, 4000, 8000, 10000, 10000]) {
    await jest.advanceTimersByTimeAsync(d - 1);
    expect([d, dev.connectCalls]).toEqual([d, calls]); // too early
    await jest.advanceTimersByTimeAsync(1);
    calls++;
    expect([d, dev.connectCalls]).toEqual([d, calls]); // missing
  }
  // success resets the backoff
  dev.incompleteDiscoveries = 0;
  await jest.advanceTimersByTimeAsync(10_000);
  expect(link.currentState).toBe('ready');
  const ready = dev.connectCalls;
  dev.drop();
  await jest.advanceTimersByTimeAsync(499);
  expect(dev.connectCalls).toBe(ready);
  await jest.advanceTimersByTimeAsync(1);
  expect(dev.connectCalls).toBe(ready + 1);
});

test('a stale write failing after a services reset keeps the new text', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  const old = (dev.text.gate = new Deferred());
  const oldSend = link.sendText('a'.repeat(60), 'subtitle');
  await settle();
  states.length = 0;
  dev.fireServicesReset();
  await until(lastIsReady);
  dev.writes.length = 0;
  const fresh = (dev.text.gate = new Deferred());
  const newSend = link.sendText('b'.repeat(60), 'subtitle');
  await settle();
  old.reject(new Error('dead characteristic'));
  await oldSend;
  fresh.resolve();
  dev.text.gate = null;
  await newSend;
  expect(bytes(dev.textWrites.map(w => w.data))).toEqual(
    bytes(frameText('b'.repeat(60), 'subtitle', 20)),
  );
});

test('a stale write failing after a reconnect keeps the new text', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  const old = (dev.text.gate = new Deferred());
  const oldSend = link.sendText('a'.repeat(60), 'subtitle');
  await settle();
  states.length = 0;
  dev.drop();
  dev.text.gate = null;
  await until(lastIsReady);
  dev.writes.length = 0;
  const fresh = (dev.text.gate = new Deferred());
  const newSend = link.sendText('b'.repeat(60), 'subtitle');
  await settle();
  old.reject(new Error('dead link'));
  await oldSend;
  fresh.resolve();
  dev.text.gate = null;
  await newSend;
  expect(bytes(dev.textWrites.map(w => w.data))).toEqual(
    bytes(frameText('b'.repeat(60), 'subtitle', 20)),
  );
});

test('a failing write clears only the rest of its own text', async () => {
  const dev = new FakeDevice(20);
  await start(dev);
  const gate = (dev.text.gate = new Deferred());
  const send = link.sendText('a'.repeat(60), 'subtitle');
  await settle();
  gate.reject(new Error('write failed'));
  await send;
  dev.text.gate = null;
  dev.writes.length = 0;
  await link.sendText('xin chào', 'subtitle');
  expect(dev.textWrites).toHaveLength(1);
  expect(payloadOf(dev.textWrites[0])).toBe('xin chào');
});

test('Bluetooth coming back on resets the backoff', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  dev.incompleteDiscoveries = 100;
  adapter.scanned.push(dev);
  makeLink();
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(4000); // attempts at 0, .5, 1.5, 3.5
  expect(dev.connectCalls).toBe(4);
  adapter.power(false);
  await jest.advanceTimersByTimeAsync(0);
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  const before = dev.connectCalls;
  await jest.advanceTimersByTimeAsync(500); // first retry: base delay
  expect(dev.connectCalls).toBe(before + 1);
});

test('rediscovery failing after a services reset falls back to reconnect', async () => {
  const dev = new FakeDevice();
  await start(dev);
  dev.incompleteDiscoveries = 1;
  states.length = 0;
  dev.fireServicesReset();
  await until(lastIsReady);
  expect(states).toContain('scanning');
  expect(dev.connectCalls).toBe(2);
});

test('dispose disconnects, stops events and Bluetooth tracking', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 0 });
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  const audio: Uint8Array[] = [];
  link.on('audio', a => audio.push(a));
  link.dispose();
  expect(dev.disconnectCalls).toBe(1);
  expect(adapter.powerSubscribers).toBe(0);
  expect(dev.connectionListeners).toBe(0);
  expect(dev.audio.subscribers).toBe(0);
  dev.audio.notify(Uint8Array.of(1));
  dev.writes.length = 0;
  await jest.advanceTimersByTimeAsync(60_000);
  expect(dev.writes).toEqual([]);
  expect(audio).toEqual([]);
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  expect(dev.connectCalls).toBe(1);
  await link.sendText('x', 'subtitle');
  expect(dev.writes).toEqual([]);
  link.dispose(); // idempotent
});

test('a throwing subscriber does not break the link', async () => {
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink({ retryDelayMs: 0 });
  link.on('state', () => {
    throw new Error('subscriber bug');
  });
  adapter.power(true);
  await until(() => states.includes('ready'));
  expect(dev.connectCalls).toBe(1);
});

// --- fix round 1 ---------------------------------------------------------------------------

test('a failed notification enable reconnects instead of a silent ready', async () => {
  const dev = new FakeDevice();
  await start(dev);
  states.length = 0;
  dev.audio.failNotify(new Error('CCCD write failed'));
  await until(lastIsReady);
  expect(states[0]).toBe('scanning');
  expect(dev.connectCalls).toBe(2);
});

test('a notification error from before a services reset is ignored', async () => {
  const dev = new FakeDevice();
  await start(dev);
  const stale = dev.control.errorCallbacks[0];
  states.length = 0;
  dev.fireServicesReset();
  await until(lastIsReady);
  states.length = 0;
  stale(new Error('stale subscription'));
  await settle();
  expect(states).toEqual([]);
  expect(link.currentState).toBe('ready');
  expect(dev.connectCalls).toBe(1);
});

test('a failing keepalive notices the dead link within 20 s', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink();
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  expect(link.currentState).toBe('ready');
  dev.control.failWithResponse = new Error('link dead');
  states.length = 0;
  await jest.advanceTimersByTimeAsync(20_000);
  expect(states[0]).toBe('scanning');
  dev.control.failWithResponse = null;
  await jest.advanceTimersByTimeAsync(500);
  expect(dev.connectCalls).toBe(2);
  expect(link.currentState).toBe('ready');
});

test('the retry waits for the disconnect to finish', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink();
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  const gate = (dev.disconnectGate = new Deferred());
  dev.drop();
  await jest.advanceTimersByTimeAsync(900); // past the 500 ms retry delay; cancel still pending
  expect(dev.disconnectCalls).toBe(1);
  expect(dev.connectCalls).toBe(1);
  dev.disconnectGate = null;
  gate.resolve();
  await jest.advanceTimersByTimeAsync(499); // the retry delay starts only now
  expect(dev.connectCalls).toBe(1);
  await jest.advanceTimersByTimeAsync(1);
  expect(dev.connectCalls).toBe(2);
});

test('a hung disconnect delays the retry by at most 1 s', async () => {
  jest.useFakeTimers();
  const dev = new FakeDevice();
  adapter.scanned.push(dev);
  makeLink();
  adapter.power(true);
  await jest.advanceTimersByTimeAsync(0);
  dev.disconnectGate = new Deferred(); // never settles
  dev.drop();
  await jest.advanceTimersByTimeAsync(1499); // 1 s timeout + 500 ms retry delay
  expect(dev.connectCalls).toBe(1);
  dev.disconnectGate = null;
  await jest.advanceTimersByTimeAsync(1);
  expect(dev.connectCalls).toBe(2);
});
