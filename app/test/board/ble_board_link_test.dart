import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/ble_adapter.dart';
import 'package:live_translator/board/ble_board_link.dart';
import 'package:live_translator/board/board_link.dart';
import 'package:live_translator/board/protocol.dart';
import 'package:live_translator/core/model.dart';

class Write {
  Write(this.uuid, this.data, this.withResponse);
  final String uuid;
  final Uint8List data;
  final bool withResponse;
  @override
  String toString() => '$uuid ${data.toList()} resp=$withResponse';
}

class FakeChar implements BleCharacteristic {
  FakeChar(this.uuid, this.dev, {this.readValue});
  final String uuid;
  final FakeDevice dev;
  Uint8List? readValue;
  final notify = StreamController<Uint8List>.broadcast();
  Completer<void>? gate;

  @override
  Future<void> write(Uint8List data, {required bool withResponse}) async {
    if (!withResponse && gate != null) await gate!.future;
    dev.writes.add(Write(uuid, data, withResponse));
  }

  @override
  Future<Uint8List> read() async => readValue!;

  @override
  Future<Stream<Uint8List>> subscribe() async => notify.stream;
}

class FakeDevice implements BleDevice {
  FakeDevice({this.maxWrite = 20, Uint8List? info}) {
    chars = {
      boardAudioUuid.toLowerCase(): FakeChar(boardAudioUuid, this),
      boardTextUuid.toLowerCase(): FakeChar(boardTextUuid, this),
      boardControlUuid.toLowerCase(): FakeChar(boardControlUuid, this),
      if (info != null)
        boardInfoUuid.toLowerCase(): FakeChar(
          boardInfoUuid,
          this,
          readValue: info,
        ),
    };
  }
  final int maxWrite;
  late final Map<String, FakeChar> chars;
  final writes = <Write>[];
  final _conn = StreamController<bool>.broadcast();
  int connectCalls = 0;
  bool failNextConnect = false;

  FakeChar get text => chars[boardTextUuid.toLowerCase()]!;
  FakeChar get audio => chars[boardAudioUuid.toLowerCase()]!;
  FakeChar get control => chars[boardControlUuid.toLowerCase()]!;

  List<Write> get textWrites =>
      writes.where((w) => w.uuid == boardTextUuid).toList();
  List<Write> get controlWrites =>
      writes.where((w) => w.uuid == boardControlUuid).toList();

  void drop() => _conn.add(false);

  @override
  String get id => 'fake';
  @override
  Stream<bool> get connected => _conn.stream;
  @override
  int get maxWriteWithoutResponse => maxWrite;
  @override
  Future<void> connect() async {
    connectCalls++;
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('connect failed');
    }
    _conn.add(true);
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<Map<String, BleCharacteristic>> discover(String uuid) async => chars;
}

class FakeAdapter implements BleAdapter {
  final _power = StreamController<bool>.broadcast();
  FakeDevice? known;
  final scanned = <FakeDevice>[];
  int scans = 0;
  int scanCancels = 0;

  @override
  Stream<bool> get powered => _power.stream;
  @override
  Future<BleDevice?> knownDevice(String serviceUuid) async => known;
  @override
  Stream<BleDevice> scan(String serviceUuid) {
    scans++;
    late StreamController<BleDevice> c;
    c = StreamController<BleDevice>(
      onListen: () {
        for (final d in scanned) {
          c.add(d);
        }
      },
      onCancel: () => scanCancels++,
    );
    return c.stream;
  }

  void power(bool on) => _power.add(on);
}

Uint8List infoBytes(int version, int sets) => Uint8List.fromList([
  version,
  sets & 0xff,
  sets >> 8 & 0xff,
  sets >> 16 & 0xff,
  sets >> 24 & 0xff,
]);

Future<void> settle() => Future<void>.delayed(Duration.zero);

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await settle();
  }
  expect(ok(), isTrue, reason: 'condition not reached');
}

String payloadOf(Write w) => utf8.decode(w.data.sublist(2));

final clock = DateTime.utc(2026, 1, 2, 3, 4, 5);

void main() {
  late FakeAdapter adapter;
  late BleBoardLink link;
  late List<BoardState> states;

  Future<void> start(FakeDevice dev, {bool viaScan = true}) async {
    if (viaScan) {
      adapter.scanned.add(dev);
    } else {
      adapter.known = dev;
    }
    link = BleBoardLink(adapter, retryDelay: Duration.zero, now: () => clock);
    states = [];
    link.state.listen(states.add);
    adapter.power(true);
    await until(() => states.contains(BoardState.ready));
  }

  setUp(() => adapter = FakeAdapter());
  tearDown(() => link.dispose());

  test('scans, connects, sets the clock with response, then mic on', () async {
    final dev = FakeDevice(maxWrite: 100, info: infoBytes(1, 0x3));
    await start(dev);
    expect(states, [
      BoardState.scanning,
      BoardState.connecting,
      BoardState.ready,
    ]);
    expect(adapter.scanCancels, 1);
    final t = dev.textWrites.single;
    expect(t.withResponse, isTrue);
    expect(t.data.toList(), timeFrame(clock).toList());
    final c = dev.controlWrites.single;
    expect(c.data.toList(), [1]);
    expect(c.withResponse, isTrue);
  });

  test('uses an already connected system device without scanning', () async {
    await start(FakeDevice(), viaScan: false);
    expect(adapter.scans, 0);
  });

  test('info is read from 0005; defaults when absent', () async {
    await start(FakeDevice(info: infoBytes(1, 0x3)));
    expect(link.info, parseBoardInfo(infoBytes(1, 0x3)));
    expect(link.info.protocolVersion, 1);

    link.dispose();
    adapter = FakeAdapter();
    await start(FakeDevice());
    expect(
      link.info,
      const BoardInfo(protocolVersion: 0, fontSets: FontSets.latinVI),
    );
  });

  test('audio is raw; control notify becomes mic events', () async {
    final dev = FakeDevice();
    await start(dev);
    final audio = <Uint8List>[];
    final ctl = <BoardControl>[];
    link.audio.listen(audio.add);
    link.control.listen(ctl.add);
    dev.audio.notify.add(Uint8List.fromList([9, 8, 7]));
    dev.control.notify.add(Uint8List.fromList([1]));
    dev.control.notify.add(Uint8List.fromList([0]));
    dev.control.notify.add(Uint8List(0));
    await settle();
    expect(audio.single, [9, 8, 7]);
    expect(ctl.map((e) => (e as BoardMicChanged).on), [true, false]);
  });

  test('sendText frames by MTU and writes without response in order', () async {
    final dev = FakeDevice(maxWrite: 20);
    await start(dev);
    dev.writes.clear();
    await link.sendText('a' * 40, TextKind.subtitle);
    final w = dev.textWrites;
    expect(w.length, 3);
    expect(w.every((x) => !x.withResponse), isTrue);
    expect(
      w.map((x) => x.data.toList()),
      frameText('a' * 40, TextKind.subtitle, 20).map((x) => x.toList()),
    );
  });

  test('a new text replaces unsent chunks of the previous one', () async {
    final dev = FakeDevice(maxWrite: 20);
    await start(dev);
    dev.writes.clear();
    final gate = dev.text.gate = Completer<void>();
    final first = link.sendText('a' * 40, TextKind.subtitle);
    await settle();
    final second = link.sendText('bbb', TextKind.subtitle);
    gate.complete();
    await first;
    await second;
    final w = dev.textWrites;
    // chunk 1 of the old text was already in flight; the rest is dropped
    expect(payloadOf(w.first), 'a' * 18);
    expect(w.length, 2);
    expect(
      w.last.data.toList(),
      frameText('bbb', TextKind.subtitle, 20).single.toList(),
    );
  });

  test('sendText and setBoardMic before ready do nothing', () async {
    link = BleBoardLink(adapter, retryDelay: Duration.zero);
    await link.sendText('x', TextKind.subtitle);
    await link.setBoardMic(true);
    expect(adapter.scans, 0);
  });

  test('label is sent only when 0005 exists', () async {
    final old = FakeDevice();
    await start(old);
    old.writes.clear();
    await link.sendText('Chủ tịch', TextKind.label);
    expect(old.textWrites, isEmpty);

    link.dispose();
    adapter = FakeAdapter();
    final neu = FakeDevice(maxWrite: 100, info: infoBytes(1, 0x3));
    await start(neu);
    neu.writes.clear();
    await link.sendText('x' * 40, TextKind.label);
    final w = neu.textWrites.single;
    expect(w.data[1], 3);
    expect(payloadOf(w).length, 32);
  });

  test('setBoardMic writes [1]/[0] with response', () async {
    final dev = FakeDevice();
    await start(dev);
    dev.writes.clear();
    await link.setBoardMic(false);
    await link.setBoardMic(true);
    expect(dev.controlWrites.map((w) => w.data.toList()), [
      [0],
      [1],
    ]);
    expect(dev.controlWrites.every((w) => w.withResponse), isTrue);
  });

  test('drop: reconnects, resends time and label, next subtitle goes out', () async {
    final dev = FakeDevice(maxWrite: 100, info: infoBytes(1, 0x3));
    await start(dev);
    await link.sendText('Chủ tịch', TextKind.label);
    dev.writes.clear();
    states.clear();

    dev.drop();
    await until(() => states.isNotEmpty && states.last == BoardState.ready);
    expect(states.first, BoardState.scanning);
    expect(dev.connectCalls, 2);

    expect(dev.textWrites.map((w) => w.data[1]).toList(), [2, 3]);
    expect(dev.textWrites.every((w) => w.withResponse), isTrue);
    expect(payloadOf(dev.textWrites[1]), 'Chủ tịch');

    dev.writes.clear();
    await link.sendText('xin chào', TextKind.subtitle);
    final w = dev.textWrites.single;
    expect(w.data[1], 0);
    expect(payloadOf(w), 'xin chào');
  });

  test('drop on old firmware resends time but no label', () async {
    final dev = FakeDevice();
    await start(dev);
    await link.sendText('label', TextKind.label);
    dev.writes.clear();
    states.clear();
    dev.drop();
    await until(() => states.isNotEmpty && states.last == BoardState.ready);
    expect(dev.textWrites.map((w) => w.data[1]).toList(), [2]);
  });

  test('chunks pending at a drop are discarded', () async {
    final dev = FakeDevice(maxWrite: 20);
    await start(dev);
    final gate = dev.text.gate = Completer<void>();
    final f = link.sendText('a' * 60, TextKind.subtitle);
    await settle();
    dev.drop();
    await settle();
    dev.text.gate = null;
    gate.complete();
    await f;
    dev.writes.clear();
    states.clear();
    await until(() => states.isNotEmpty && states.last == BoardState.ready);
    expect(dev.textWrites.map((w) => w.data[1]).toList(), [2]);
  });

  test('a failed connect is retried', () async {
    final dev = FakeDevice()..failNextConnect = true;
    await start(dev);
    expect(dev.connectCalls, 2);
  });

  test('Bluetooth off goes to off; back on connects again', () async {
    final dev = FakeDevice();
    await start(dev);
    states.clear();
    adapter.power(false);
    await until(() => states.contains(BoardState.off));
    adapter.power(true);
    await until(() => states.contains(BoardState.ready));
    expect(dev.connectCalls, 2);
  });

  test('keepalive 0xFF on the control characteristic', () {
    fakeAsync((fa) {
      final dev = FakeDevice();
      adapter.scanned.add(dev);
      link = BleBoardLink(adapter, retryDelay: Duration.zero);
      adapter.power(true);
      fa.flushMicrotasks();
      dev.writes.clear();
      fa.elapse(const Duration(seconds: 41));
      expect(dev.controlWrites.map((w) => w.data.toList()).toList(), [
        [0xFF],
        [0xFF],
      ]);
      link.dispose();
    });
  });
}
