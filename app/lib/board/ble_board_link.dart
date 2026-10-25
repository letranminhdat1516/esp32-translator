import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/model.dart';
import 'ble_adapter.dart';
import 'board_link.dart';
import 'protocol.dart';

/// [BoardLink] over BLE. Mirrors `ios/Sources/BLE/ESPLink.swift`: find (or
/// reuse) the board, connect, subscribe to audio and control, set the clock,
/// switch the board mic on, keep the link alive, and rescan after a drop.
class BleBoardLink implements BoardLink {
  BleBoardLink(
    this._adapter, {
    DateTime Function()? now,
    this.retryDelay = const Duration(milliseconds: 500),
    this.keepaliveInterval = const Duration(seconds: 20),
  }) : _now = now ?? DateTime.now {
    _powerSub = _adapter.powered.listen(_onPower);
  }

  /// Control byte the board takes as "the app is alive" (0..2 are mic states).
  static const keepaliveByte = 0xFF;

  final BleAdapter _adapter;
  final DateTime Function() _now;

  /// Pause before rescanning after a drop or a failed connect. Swift rescans
  /// at once; the pause only keeps a failing connect from spinning.
  final Duration retryDelay;
  final Duration keepaliveInterval;

  final _state = StreamController<BoardState>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  final _control = StreamController<BoardControl>.broadcast();

  StreamSubscription<bool>? _powerSub;
  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<bool>? _connSub;
  final _notifySubs = <StreamSubscription<Uint8List>>[];
  Timer? _retry;
  Timer? _keepalive;

  bool _powered = false;
  bool _disposed = false;

  /// Bumped whenever the current attempt is abandoned; stale async steps stop.
  int _gen = 0;
  BleDevice? _device;
  BleCharacteristic? _textChar;
  BleCharacteristic? _controlChar;
  bool _ready = false;
  bool _labelSupported = false;
  String? _lastLabel;
  BoardState _current = BoardState.off;

  /// Chunks not yet written; a new text replaces them.
  final Queue<Uint8List> _pending = Queue();
  Future<void>? _flushing;

  @override
  BoardInfo info = const BoardInfo(
    protocolVersion: 0,
    fontSets: FontSets.latinVI,
  );

  @override
  Stream<BoardState> get state => _state.stream;
  @override
  Stream<Uint8List> get audio => _audio.stream;
  @override
  Stream<BoardControl> get control => _control.stream;

  void _setState(BoardState s) {
    if (_disposed) return;
    _current = s;
    _state.add(s);
  }

  void _onPower(bool on) {
    _powered = on;
    if (on) {
      if (_current == BoardState.off) unawaited(_startScan());
    } else {
      _abandon();
      _setState(BoardState.off);
    }
  }

  /// Drops everything tied to the current link (not the Bluetooth power
  /// subscription).
  void _abandon() {
    _gen++;
    _retry?.cancel();
    _retry = null;
    _keepalive?.cancel();
    _keepalive = null;
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    unawaited(_connSub?.cancel());
    _connSub = null;
    for (final s in _notifySubs) {
      unawaited(s.cancel());
    }
    _notifySubs.clear();
    _pending.clear();
    _textChar = null;
    _controlChar = null;
    _ready = false;
    final dev = _device;
    _device = null;
    if (dev != null) unawaited(dev.disconnect().catchError((_) {}));
  }

  void _scheduleRetry() {
    if (_disposed || !_powered) return;
    _retry?.cancel();
    _retry = Timer(retryDelay, () {
      if (!_disposed && _powered) unawaited(_startScan());
    });
  }

  Future<void> _startScan() async {
    _abandon();
    final gen = _gen;
    _setState(BoardState.scanning);
    try {
      final known = await _adapter.knownDevice(boardServiceUuid);
      if (gen != _gen) return;
      if (known != null) {
        unawaited(_connect(known, gen));
        return;
      }
      _scanSub = _adapter
          .scan(boardServiceUuid)
          .listen(
            (dev) {
              if (gen != _gen) return;
              unawaited(_scanSub?.cancel());
              _scanSub = null;
              unawaited(_connect(dev, gen));
            },
            onError: (Object _) {
              if (gen == _gen) _scheduleRetry();
            },
          );
    } catch (_) {
      if (gen == _gen) _scheduleRetry();
    }
  }

  Future<void> _connect(BleDevice dev, int gen) async {
    _device = dev;
    _setState(BoardState.connecting);
    // Listen before connecting so a drop is never missed. The first `true`
    // is the connect itself; a `false` after it is a drop.
    var wasUp = false;
    _connSub = dev.connected.listen((up) {
      if (gen != _gen) return;
      if (up) {
        wasUp = true;
      } else if (wasUp) {
        _onDrop();
      }
    });
    try {
      await dev.connect();
      if (gen != _gen) return;
      final chars = await dev.discover(boardServiceUuid);
      if (gen != _gen) return;
      await _setUp(dev, chars, gen);
    } catch (_) {
      if (gen == _gen) _onDrop();
    }
  }

  void _onDrop() {
    _abandon();
    if (_disposed) return;
    _setState(_powered ? BoardState.scanning : BoardState.off);
    _scheduleRetry();
  }

  Future<void> _setUp(
    BleDevice dev,
    Map<String, BleCharacteristic> chars,
    int gen,
  ) async {
    final text = chars[boardTextUuid.toLowerCase()];
    final ctl = chars[boardControlUuid.toLowerCase()];
    final aud = chars[boardAudioUuid.toLowerCase()];
    if (text == null || ctl == null) throw StateError('board GATT incomplete');

    if (aud != null) {
      final s = await aud.subscribe();
      if (gen != _gen) return;
      _notifySubs.add(s.listen(_audio.add));
    }
    final cs = await ctl.subscribe();
    if (gen != _gen) return;
    _notifySubs.add(
      cs.listen((v) {
        if (v.isNotEmpty) _control.add(BoardMicChanged(v[0] != 0));
      }),
    );

    // Board info: absent on older firmware.
    final infoChar = chars[boardInfoUuid.toLowerCase()];
    var parsed = false;
    var boardInfo = const BoardInfo(
      protocolVersion: 0,
      fontSets: FontSets.latinVI,
    );
    if (infoChar != null) {
      try {
        final p = parseBoardInfo(await infoChar.read());
        if (p != null) {
          boardInfo = p;
          parsed = true;
        }
      } catch (_) {}
      if (gen != _gen) return;
    }
    info = boardInfo;
    _labelSupported = parsed;

    _textChar = text;
    _controlChar = ctl;
    // Clock first (with response: never dropped or replaced by a subtitle),
    // then the label the board forgot, then the mic.
    await text.write(timeFrame(_now()), withResponse: true);
    if (gen != _gen) return;
    final label = _lastLabel;
    if (_labelSupported && label != null) {
      for (final chunk in frameText(
        labelText(label),
        TextKind.label,
        dev.maxWriteWithoutResponse,
      )) {
        await text.write(chunk, withResponse: true);
        if (gen != _gen) return;
      }
    }
    await ctl.write(Uint8List.fromList([1]), withResponse: true);
    if (gen != _gen) return;
    _keepalive = Timer.periodic(keepaliveInterval, (_) {
      final c = _controlChar;
      if (c == null) return;
      c
          .write(Uint8List.fromList([keepaliveByte]), withResponse: true)
          .catchError((_) {});
    });
    _ready = true;
    _setState(BoardState.ready);
  }

  @override
  Future<void> sendText(String text, TextKind kind) {
    if (kind == TextKind.label) {
      _lastLabel = text;
      if (!_labelSupported) return Future.value();
    }
    final dev = _device;
    if (!_ready || dev == null) return Future.value();
    final shown = kind == TextKind.label ? labelText(text) : text;
    _pending
      ..clear()
      ..addAll(frameText(shown, kind, dev.maxWriteWithoutResponse));
    return _flush();
  }

  /// Writes pending chunks one at a time; reads the queue afresh after each
  /// write, so a replacement text takes over at the next chunk boundary.
  Future<void> _flush() => _flushing ??= () async {
    final gen = _gen;
    try {
      while (_pending.isNotEmpty && gen == _gen) {
        final c = _textChar;
        if (c == null) break;
        await c.write(_pending.removeFirst(), withResponse: false);
      }
    } catch (_) {
      _pending.clear();
    } finally {
      _flushing = null;
    }
  }();

  @override
  Future<void> setBoardMic(bool on) async {
    final c = _controlChar;
    if (!_ready || c == null) return;
    try {
      await c.write(Uint8List.fromList([on ? 1 : 0]), withResponse: true);
    } catch (_) {}
  }

  /// Stops scanning, disconnects and closes the streams.
  void dispose() {
    if (_disposed) return;
    _abandon();
    _disposed = true;
    unawaited(_powerSub?.cancel());
    _state.close();
    _audio.close();
    _control.close();
  }
}
