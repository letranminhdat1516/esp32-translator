import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/board_link.dart';
import 'package:live_translator/board/fake_board_link.dart';
import 'package:live_translator/board/protocol.dart';
import 'package:live_translator/core/model.dart';

void main() {
  test('records texts and mic calls in order', () async {
    final link = FakeBoardLink();
    await link.sendText('a', TextKind.subtitle);
    await link.sendText('b', TextKind.label);
    await link.setBoardMic(true);
    await link.setBoardMic(false);
    expect(link.sentTexts, [('a', TextKind.subtitle), ('b', TextKind.label)]);
    expect(link.micCalls, [true, false]);
  });

  test('default info and settable info', () {
    final link = FakeBoardLink();
    expect(
      link.info,
      const BoardInfo(protocolVersion: 0, fontSets: FontSets.latinVI),
    );
    link.info = const BoardInfo(protocolVersion: 1, fontSets: FontSets.cjk);
    expect(link.info.protocolVersion, 1);
  });

  test('emits state, audio and control', () async {
    final link = FakeBoardLink();
    final states = <BoardState>[];
    final audio = <Uint8List>[];
    final control = <BoardControl>[];
    link.state.listen(states.add);
    link.audio.listen(audio.add);
    link.control.listen(control.add);
    link.emitState(BoardState.ready);
    link.emitAudio(Uint8List.fromList([1]));
    link.emitControl(const BoardMicChanged(true));
    await Future<void>.delayed(Duration.zero);
    expect(states, [BoardState.ready]);
    expect(audio.single, [1]);
    expect((control.single as BoardMicChanged).on, isTrue);
  });
}
