import 'dart:typed_data';

import '../core/model.dart';
import 'protocol.dart';

/// Connection state of the board link.
enum BoardState { off, scanning, connecting, ready }

/// An event the board sends on the control characteristic.
sealed class BoardControl {
  const BoardControl();
}

/// The board's mic was switched by the on-screen button. Comes from a notify
/// on the control characteristic whose first byte is the state (non-zero =
/// on); `ESPLink.onMicChange` in the Swift app.
class BoardMicChanged extends BoardControl {
  const BoardMicChanged(this.on);
  final bool on;
}

/// The phone's side of the subtitle board.
abstract class BoardLink {
  Stream<BoardState> get state;

  /// Audio packets from the board mic (`…0002` notifications).
  Stream<Uint8List> get audio;

  /// Board-originated control events.
  Stream<BoardControl> get control;

  /// What the board can render. When the board has no `…0005` characteristic
  /// (older firmware) this is `BoardInfo(protocolVersion: 0,
  /// fontSets: FontSets.latinVI)`.
  BoardInfo get info;

  /// Frames and writes [text]; a new message replaces an unsent one.
  Future<void> sendText(String text, TextKind kind);

  /// Switches the board's mic (control characteristic write).
  Future<void> setBoardMic(bool on);
}
