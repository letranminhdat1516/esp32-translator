import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';

String _read(String name) =>
    File('assets/languages/$name.json').readAsStringSync();

Map<String, dynamic> _base() => jsonDecode(_read('en')) as Map<String, dynamic>;

void main() {
  group('LanguagePack.parse', () {
    test('vi.json parses', () {
      final p = LanguagePack.parse(_read('vi'));
      expect(p.code, 'vi');
      expect(p.appleLocale, 'vi-VN');
      expect(p.androidLocale, 'vi-VN');
      expect(p.whisperCode, 'vi');
      expect(p.label, 'Tiếng Việt');
      expect(p.labelLatin, 'VI');
      expect(p.script, Script.latin);
      expect(p.minConfidence, isNull);
      expect(p.recognition, isEmpty);
      expect(p.beforeTranslation, isEmpty);
      expect(p.terms, isEmpty);
      expect(p.hints, isEmpty);
    });

    test('en.json parses', () {
      final p = LanguagePack.parse(_read('en'));
      expect(p.code, 'en');
      expect(p.appleLocale, 'en-US');
      expect(p.androidLocale, 'en-US');
      expect(p.whisperCode, 'en');
      expect(p.label, 'English');
      expect(p.labelLatin, 'EN');
      expect(p.minConfidence, 0.4);
    });

    test('missing label throws PackError(label)', () {
      final m = _base()..remove('label');
      expect(
        () => LanguagePack.parse(jsonEncode(m)),
        throwsA(isA<PackError>().having((e) => e.field, 'field', 'label')),
      );
    });

    test(
      'invalid recognition pattern throws PackError(recognition[0].pattern)',
      () {
        final m = _base()
          ..['recognition'] = [
            {'id': 'r', 'pattern': '(', 'template': 'x'},
          ];
        expect(
          () => LanguagePack.parse(jsonEncode(m)),
          throwsA(
            isA<PackError>().having(
              (e) => e.field,
              'field',
              'recognition[0].pattern',
            ),
          ),
        );
      },
    );

    test('invalid beforeTranslation context throws with path', () {
      final m = _base()
        ..['beforeTranslation'] = [
          {'id': 'a', 'pattern': 'a', 'template': 'b'},
          {'id': 'r', 'pattern': 'a', 'template': 'b', 'context': '['},
        ];
      expect(
        () => LanguagePack.parse(jsonEncode(m)),
        throwsA(
          isA<PackError>().having(
            (e) => e.field,
            'field',
            'beforeTranslation[1].context',
          ),
        ),
      );
    });

    test('unknown script throws PackError(script)', () {
      final m = _base()..['script'] = 'klingon';
      expect(
        () => LanguagePack.parse(jsonEncode(m)),
        throwsA(isA<PackError>().having((e) => e.field, 'field', 'script')),
      );
    });
  });

  group('round trip', () {
    test('full pack toJson/parse equals', () {
      final m = _base()
        ..['script'] = 'cjk'
        ..['recognition'] = [
          {
            'id': 'r1',
            'pattern': r'\bfoo\b',
            'template': 'bar',
            'atClauseStart': true,
            'context': 'baz',
          },
        ]
        ..['beforeTranslation'] = [
          {'id': 'b1', 'pattern': 'x', 'template': 'y'},
        ]
        ..['terms'] = [
          {
            'id': 't1',
            'text': 'Tuan',
            'variants': ['Tuấn', 'Toan'],
            'fixed': {'en': 'Tuan'},
            'origin': 'user',
          },
        ]
        ..['hints'] = ['a', 'b'];
      final p = LanguagePack.parse(jsonEncode(m));
      final again = LanguagePack.parse(jsonEncode(p.toJson()));
      expect(again, p);
      expect(again.hashCode, p.hashCode);
      expect(again.recognition.single.atClauseStart, isTrue);
      expect(again.terms.single.origin, TermOrigin.user);
    });

    test('shipped packs round trip', () {
      for (final n in ['vi', 'en']) {
        final p = LanguagePack.parse(_read(n));
        expect(LanguagePack.parse(jsonEncode(p.toJson())), p);
      }
    });
  });

  group('FontSets', () {
    test('bit values', () {
      expect(FontSets.latinVI.value, 1);
      expect(FontSets.latinExtA.value, 2);
      expect(FontSets.cjk.value, 4);
      expect(FontSets.hangul.value, 8);
      expect(FontSets.thai.value, 16);
    });

    test('FontSets(latinVI) does not cover cjk', () {
      expect(FontSets.latinVI.covers(Script.cjk), isFalse);
    });

    test('covers mapping', () {
      expect(FontSets.latinVI.covers(Script.latin), isTrue);
      expect(FontSets.latinExtA.covers(Script.latin), isTrue);
      expect(FontSets.cjk.covers(Script.latin), isFalse);
      expect(FontSets.cjk.covers(Script.cjk), isTrue);
      expect(FontSets.hangul.covers(Script.hangul), isTrue);
      expect(FontSets.thai.covers(Script.thai), isTrue);
      final all = FontSets.fromInt(31);
      expect(all.covers(Script.cyrillic), isFalse);
      expect(all.covers(Script.other), isFalse);
    });

    test('| and contains and equality', () {
      final s = FontSets.latinVI | FontSets.thai;
      expect(s.value, 17);
      expect(s.contains(FontSets.thai), isTrue);
      expect(s.contains(FontSets.cjk), isFalse);
      expect(s, FontSets.fromInt(17));
      expect(s.hashCode, FontSets.fromInt(17).hashCode);
    });
  });

  group('Capabilities and BoardInfo', () {
    test('value equality', () {
      Capabilities mk() => Capabilities(
        recognizers: {
          'en': [RecognizerKind.osOnDevice, RecognizerKind.whisper],
        },
        translatable: {'en', 'ja'},
        vietnameseVoice: true,
      );
      expect(mk(), mk());
      expect(mk().hashCode, mk().hashCode);
      expect(
        mk(),
        isNot(
          Capabilities(
            recognizers: {
              'en': [RecognizerKind.osOnline],
            },
            translatable: {'en', 'ja'},
            vietnameseVoice: true,
          ),
        ),
      );
      expect(
        BoardInfo(protocolVersion: 1, fontSets: FontSets.latinVI),
        BoardInfo(protocolVersion: 1, fontSets: FontSets.latinVI),
      );
      expect(
        BoardInfo(protocolVersion: 1, fontSets: FontSets.latinVI),
        isNot(BoardInfo(protocolVersion: 2, fontSets: FontSets.latinVI)),
      );
    });
  });
}
