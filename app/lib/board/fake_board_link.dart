import 'dart:async';
import 'dart:typed_data';

import '../core/model.dart';
import 'board_link.dart';
import 'protocol.dart';

/// In-memory [BoardLink] for tests: records writes, emits on demand.
class FakeBoardLink implements BoardLink {
  final _state = StreamController<BoardState>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  final _control = StreamController<BoardControl>.broadcast();

  /// Every [sendText] call, in order.
  final List<(String, TextKind)> sentTexts = [];

  /// Every [setBoardMic] call, in order.
  final List<bool> micCalls = [];

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

  @override
  Future<void> sendText(String text, TextKind kind) async =>
      sentTexts.add((text, kind));

  @override
  Future<void> setBoardMic(bool on) async => micCalls.add(on);

  void emitState(BoardState s) => _state.add(s);
  void emitAudio(Uint8List data) => _audio.add(data);
  void emitControl(BoardControl c) => _control.add(c);
}
