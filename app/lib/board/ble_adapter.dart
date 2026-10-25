import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

/// One GATT characteristic of a connected board.
abstract class BleCharacteristic {
  /// Write with or without response. Without response completes once the
  /// stack has accepted the packet (the adapter paces itself).
  Future<void> write(Uint8List data, {required bool withResponse});

  Future<Uint8List> read();

  /// Enables notifications and returns the stream of values.
  Future<Stream<Uint8List>> subscribe();
}

/// A peripheral found by [BleAdapter].
abstract class BleDevice {
  String get id;

  /// True while connected; emits false on every drop.
  Stream<bool> get connected;

  Future<void> connect();
  Future<void> disconnect();

  /// Characteristics of [serviceUuid] keyed by lower-case UUID; empty when the
  /// service is missing.
  Future<Map<String, BleCharacteristic>> discover(String serviceUuid);

  /// Largest write-without-response payload (ATT MTU - 3).
  int get maxWriteWithoutResponse;
}

/// The few Bluetooth calls [BleBoardLink] needs.
abstract class BleAdapter {
  /// Bluetooth radio on/off.
  Stream<bool> get powered;

  /// An already connected (system) device with [serviceUuid], if any.
  Future<BleDevice?> knownDevice(String serviceUuid);

  /// Devices advertising [serviceUuid]; cancelling the subscription stops the
  /// scan.
  Stream<BleDevice> scan(String serviceUuid);
}

/// [BleAdapter] on top of flutter_blue_plus.
class FlutterBluePlusAdapter implements BleAdapter {
  @override
  Stream<bool> get powered => fbp.FlutterBluePlus.adapterState.map(
    (s) => s == fbp.BluetoothAdapterState.on,
  );

  @override
  Future<BleDevice?> knownDevice(String serviceUuid) async {
    final known = await fbp.FlutterBluePlus.systemDevices([
      fbp.Guid(serviceUuid),
    ]);
    return known.isEmpty ? null : _FbpDevice(known.first);
  }

  @override
  Stream<BleDevice> scan(String serviceUuid) {
    late StreamController<BleDevice> out;
    StreamSubscription<List<fbp.ScanResult>>? sub;
    out = StreamController<BleDevice>(
      onListen: () async {
        sub = fbp.FlutterBluePlus.onScanResults.listen((results) {
          if (results.isNotEmpty) out.add(_FbpDevice(results.last.device));
        }, onError: out.addError);
        try {
          await fbp.FlutterBluePlus.startScan(
            withServices: [fbp.Guid(serviceUuid)],
          );
        } catch (e, st) {
          out.addError(e, st);
        }
      },
      onCancel: () async {
        await sub?.cancel();
        await fbp.FlutterBluePlus.stopScan();
      },
    );
    return out.stream;
  }
}

class _FbpDevice implements BleDevice {
  _FbpDevice(this._d);
  final fbp.BluetoothDevice _d;

  @override
  String get id => _d.remoteId.str;

  @override
  Stream<bool> get connected => _d.connectionState.map(
    (s) => s == fbp.BluetoothConnectionState.connected,
  );

  // flutter_blue_plus 2.x requires a license choice; this is a personal app.
  @override
  Future<void> connect() => _d.connect(license: fbp.License.nonprofit);

  @override
  Future<void> disconnect() => _d.disconnect();

  @override
  int get maxWriteWithoutResponse => _d.mtuNow - 3;

  @override
  Future<Map<String, BleCharacteristic>> discover(String serviceUuid) async {
    final want = fbp.Guid(serviceUuid);
    final services = await _d.discoverServices();
    final out = <String, BleCharacteristic>{};
    for (final s in services) {
      if (s.serviceUuid != want) continue;
      for (final c in s.characteristics) {
        out[c.characteristicUuid.str128.toLowerCase()] = _FbpChar(c);
      }
    }
    return out;
  }
}

class _FbpChar implements BleCharacteristic {
  _FbpChar(this._c);
  final fbp.BluetoothCharacteristic _c;

  @override
  Future<void> write(Uint8List data, {required bool withResponse}) =>
      _c.write(data, withoutResponse: !withResponse);

  @override
  Future<Uint8List> read() async => Uint8List.fromList(await _c.read());

  @override
  Future<Stream<Uint8List>> subscribe() async {
    final values = _c.onValueReceived.map(Uint8List.fromList);
    await _c.setNotifyValue(true);
    return values;
  }
}
