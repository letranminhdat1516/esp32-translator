import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/protocol.dart';
import 'package:live_translator/core/model.dart';

String hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  test('uuids', () {
    expect(boardServiceUuid, 'A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A');
    expect(boardAudioUuid, 'A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A');
    expect(boardTextUuid, 'A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A');
    expect(boardControlUuid, 'A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A');
    expect(boardInfoUuid, 'A7C00005-3B2F-4C1E-9D8A-5F6E7D8C9B0A');
  });

  test('TextKind codes', () {
    expect(TextKind.values.map((k) => k.code), [0, 1, 2, 3]);
  });

  group('frameText', () {
    test('10 bytes at 185 is one chunk, flags 0x03', () {
      final f = frameText('0123456789', TextKind.subtitle, 185);
      expect(f, hasLength(1));
      expect(f[0][0], 0x03);
      expect(f[0][1], 0);
      expect(f[0].length, 12);
    });

    test('120 bytes at 50 gives payload 48, three chunks', () {
      final f = frameText('a' * 120, TextKind.status, 50);
      expect(f.map((c) => c[0]), [0x01, 0x00, 0x02]);
      expect(f.map((c) => c.length - 2), [48, 48, 24]);
      expect(f.every((c) => c[1] == 1), isTrue);
    });

    test('maxWrite 10 behaves as 20', () {
      final f = frameText('a' * 40, TextKind.subtitle, 10);
      expect(f.map((c) => c.length - 2), [18, 18, 4]);
    });

    test('empty text is one chunk with flags 0x03', () {
      final f = frameText('', TextKind.subtitle, 185);
      expect(f.map(hex), ['03 00']);
    });

    test('long text keeps the tail after a word boundary, with ellipsis', () {
      final text = List.generate(
        40,
        (i) => 'w${i.toString().padLeft(3, '0')}',
      ).join(' '); // 5 chars each + spaces = 199 bytes
      expect(utf8.encode(text).length, 199);
      final f = frameText(text, TextKind.subtitle, 400);
      expect(f, hasLength(1));
      final s = utf8.decode(f[0].sublist(2));
      expect(s.startsWith('…'), isTrue);
      expect(s.substring(1).startsWith('w'), isTrue);
      expect(text.endsWith(s.substring(1)), isTrue);
      expect(utf8.encode(s).length, lessThanOrEqualTo(150 + 3));
    });

    test('Xin chào kind 0 matches the Swift bytes', () {
      final f = frameText('Xin chào', TextKind.subtitle, 185);
      expect(f.map(hex), ['03 00 58 69 6e 20 63 68 c3 a0 6f']);
    });
  });

  group('time', () {
    test('timeText is unix seconds and utc offset minutes', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1761400000999, isUtc: true);
      expect(timeText(t), '1761400000 0');
    });

    test('timeFrame is one kind-2 chunk', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1761400000000);
      final frame = timeFrame(t);
      expect(frame.sublist(0, 2), [0x03, 2]);
      expect(utf8.decode(frame.sublist(2)), timeText(t));
      expect(timeText(t), matches(RegExp(r'^1761400000 -?\d+$')));
    });
  });

  group('labelText', () {
    test('cuts at a character boundary, no ellipsis', () {
      final s = labelText('日本語日本語日本語日本語');
      expect(utf8.encode(s), hasLength(30));
      expect(s.runes, hasLength(10));
    });
    test('short label unchanged', () => expect(labelText('Nhật'), 'Nhật'));
  });

  group('parseBoardInfo', () {
    test('version and font sets', () {
      final i = parseBoardInfo(Uint8List.fromList([1, 3, 0, 0, 0]))!;
      expect(i.protocolVersion, 1);
      expect(i.fontSets, FontSets.latinVI | FontSets.latinExtA);
    });
    test('short input is null', () {
      expect(parseBoardInfo(Uint8List.fromList([1, 3, 0, 0])), isNull);
    });
    test('little endian across bytes', () {
      final i = parseBoardInfo(Uint8List.fromList([2, 0x10, 0x01, 0, 0]))!;
      expect(i.fontSets.value, 0x0110);
    });
  });
}
