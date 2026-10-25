import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/engine/fake_voice_engine.dart';
import 'package:live_translator/engine/voice_engine.dart';

void main() {
  test('records speak calls in order', () async {
    final engine = FakeVoiceEngine();
    await engine.speak('xin chào', 1);
    await engine.speak('hello', 2);
    expect(engine.spoken, [(text: 'xin chào', id: 1), (text: 'hello', id: 2)]);
  });

  test('failNextTranslate throws once, then translations resume', () async {
    final engine = FakeVoiceEngine()..translations['hi'] = 'chào';
    engine.failNextTranslate();
    await expectLater(
      engine.translate('hi', 'en', 'vi'),
      throwsA(EngineError.translateFailed),
    );
    expect(await engine.translate('hi', 'en', 'vi'), 'chào');
  });

  test('emitted events arrive on the streams', () async {
    final engine = FakeVoiceEngine();
    final mine = MineMsg(
      kind: MineKind.finalText,
      text: 'a',
      startMs: 0,
      endMs: 10,
    );
    final theirs = TheirsMsg(text: 'b', confidence: null, generation: 3);
    final gate = engine.gate.first;
    final mineF = engine.mine.first;
    final theirsF = engine.theirs.first;
    engine.emitMine(mine);
    engine.emitTheirs(theirs);
    engine.emitGate(true);
    expect(await mineF, same(mine));
    expect(await theirsF, same(theirs));
    expect(await gate, true);
  });

  test('Int16List to bytes keeps sample values (little-endian)', () {
    final pcm = Int16List.fromList([0, 1, -1, 32767, -32768, 258]);
    final bytes = pcm16leBytes(pcm);
    expect(bytes.lengthInBytes, 12);
    expect(bytes.sublist(0, 6), [0, 0, 1, 0, 255, 255]);
    expect(
      Int16List.sublistView(bytes),
      orderedEquals([0, 1, -1, 32767, -32768, 258]),
    );
    // A view into a larger buffer must honour its offset.
    final view = Int16List.sublistView(Int16List.fromList([9, 8, 7, 6]), 1, 3);
    expect(Int16List.sublistView(pcm16leBytes(view)), [8, 7]);
  });

  test('CapabilitiesMsg.toModel maps recognizer names', () {
    final msg = CapabilitiesMsg(
      recognizers: {
        'ja': ['whisper', 'osOnline'],
      },
      translatable: ['ja', 'vi'],
      vietnameseVoice: false,
    );
    expect(
      msg.toModel(),
      const Capabilities(
        recognizers: {
          'ja': [RecognizerKind.whisper, RecognizerKind.osOnline],
        },
        translatable: {'ja', 'vi'},
        vietnameseVoice: false,
      ),
    );
  });
}
