import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/protocol.dart';

import '../shared_fixtures.dart';

/// An instant seen from a fixed UTC offset. Dart's DateTime only knows UTC
/// and the machine's zone; timeText reads just these two members.
class _ZonedTime implements DateTime {
  _ZonedTime(this.millisecondsSinceEpoch, this.timeZoneOffset);

  @override
  final int millisecondsSinceEpoch;

  @override
  final Duration timeZoneOffset;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

/// Cases: shared/fixtures/protocol.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('protocol');

  test('uuids', () {
    final u = fixture['uuids'] as Map<String, dynamic>;
    expect(boardServiceUuid, u['service']);
    expect(boardAudioUuid, u['audio']);
    expect(boardTextUuid, u['text']);
    expect(boardControlUuid, u['control']);
    expect(boardInfoUuid, u['info']);
  });

  test('TextKind codes and limits', () {
    expect({for (final k in TextKind.values) k.name: k.code}, fixture['textKinds']);
    expect(maxTextBytes, fixture['maxTextBytes']);
    expect(maxLabelBytes, fixture['maxLabelBytes']);
  });

  group('frameText', () {
    for (final c in casesOf(fixture, 'frameText')) {
      test(c['name'] as String, () {
        final f = frameText(c['text'] as String, TextKind.values.byName(c['kind'] as String), c['maxWrite'] as int);
        expect(f.map(hexOf), strings(c['expected']));
      });
    }
  });

  group('labelText', () {
    for (final c in casesOf(fixture, 'labelText')) {
      test(c['name'] as String, () => expect(labelText(c['input'] as String), c['expected']));
    }
  });

  group('parseBoardInfo', () {
    for (final c in casesOf(fixture, 'boardInfo')) {
      test(c['name'] as String, () {
        final info = parseBoardInfo(Uint8List.fromList(bytesOf(c['hex'] as String)));
        final want = c['expected'] as Map<String, dynamic>?;
        if (want == null) {
          expect(info, isNull);
        } else {
          expect(info!.protocolVersion, want['protocolVersion']);
          expect(info.fontSets.value, want['fontSets']);
        }
      });
    }
  });

  group('time', () {
    for (final c in casesOf(fixture, 'timeText')) {
      test(c['name'] as String, () {
        final t = _ZonedTime(c['epochMs'] as int, Duration(minutes: c['utcOffsetMinutes'] as int));
        expect(timeText(t), c['expected']);
      });
    }

    // Not fixture-driven: depends on the machine's time zone.
    test('timeFrame is one kind-2 chunk in local time', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1761400000000);
      final frame = timeFrame(t);
      expect(frame.sublist(0, 2), [0x03, 2]);
      expect(utf8.decode(frame.sublist(2)), timeText(t));
      expect(timeText(t), matches(RegExp(r'^1761400000 -?\d+$')));
    });
  });
}
