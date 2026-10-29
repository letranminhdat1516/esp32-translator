import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';

import '../shared_fixtures.dart';

String _read(String name) => File('$sharedDir/languages/$name.json').readAsStringSync();

/// A pack JSON built from `shared/languages/<base>.json` with fields set or
/// removed, as a case of model.json describes it.
String _packJson(Map<String, dynamic> c) {
  final m = jsonDecode(_read(c['base'] as String)) as Map<String, dynamic>;
  for (final k in strings(c['remove'])) {
    m.remove(k);
  }
  m.addAll((c['set'] as Map<String, dynamic>?) ?? const {});
  return jsonEncode(m);
}

/// Cases: shared/fixtures/model.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('model');

  test('enum names', () {
    expect(Script.values.map((s) => s.name), strings(fixture['scripts']));
    expect(RecognizerKind.values.map((s) => s.name), strings(fixture['recognizerKinds']));
  });

  group('shipped packs parse', () {
    for (final e in (fixture['shippedPacks'] as Map<String, dynamic>).entries) {
      test('${e.key}.json', () {
        final want = e.value as Map<String, dynamic>;
        final p = LanguagePack.parse(_read(e.key));
        expect(p.code, want['code']);
        expect(p.appleLocale, want['appleLocale']);
        expect(p.androidLocale, want['androidLocale']);
        expect(p.whisperCode, want['whisperCode']);
        expect(p.label, want['label']);
        expect(p.labelLatin, want['labelLatin']);
        expect(p.script.name, want['script']);
        expect(p.minConfidence, want['minConfidence']);
        expect(p.recognition.isNotEmpty, want['hasRecognition']);
        expect(p.beforeTranslation.isNotEmpty, want['hasBeforeTranslation']);
        expect(p.terms.length, want['termCount']);
        expect(p.hints.length, want['hintCount']);
        // Round trip (Dart toJson).
        expect(LanguagePack.parse(jsonEncode(p.toJson())), p);
      });
    }
  });

  group('packOk', () {
    for (final c in casesOf(fixture, 'packOk')) {
      test(c['name'] as String, () {
        final p = LanguagePack.parse(_packJson(c));
        final want = c['expect'] as Map<String, dynamic>;
        if (want.containsKey('script')) expect(p.script.name, want['script']);
        if (want.containsKey('recognitionCount')) expect(p.recognition.length, want['recognitionCount']);
        if (want.containsKey('atClauseStart')) expect(p.recognition.first.atClauseStart, want['atClauseStart']);
        if (want.containsKey('termOrigin')) expect(p.terms.single.origin.name, want['termOrigin']);
        if (want.containsKey('hints')) expect(p.hints, strings(want['hints']));
        if (want.containsKey('minConfidence')) expect(p.minConfidence, want['minConfidence']);
        // Round trip (Dart toJson).
        final again = LanguagePack.parse(jsonEncode(p.toJson()));
        expect(again, p);
        expect(again.hashCode, p.hashCode);
      });
    }
  });

  group('packErrors', () {
    for (final c in casesOf(fixture, 'packErrors')) {
      test('${c['name']} throws PackError(${c['field']})', () {
        expect(
          () => LanguagePack.parse(_packJson(c)),
          throwsA(isA<PackError>().having((e) => e.field, 'field', c['field'])),
        );
      });
    }
  });

  group('FontSets', () {
    test('bit values', () {
      final bits = fixture['fontSetBits'] as Map<String, dynamic>;
      expect(FontSets.latinVI.value, bits['latinVI']);
      expect(FontSets.latinExtA.value, bits['latinExtA']);
      expect(FontSets.cjk.value, bits['cjk']);
      expect(FontSets.hangul.value, bits['hangul']);
      expect(FontSets.thai.value, bits['thai']);
    });

    for (final c in casesOf(fixture, 'covers')) {
      test(c['name'] as String, () {
        expect(FontSets.fromInt(c['fontSets'] as int).covers(Script.values.byName(c['script'] as String)), c['expected']);
      });
    }

    // Not fixture-driven: Dart operators and equality.
    test('| and contains and equality', () {
      final s = FontSets.latinVI | FontSets.thai;
      expect(s.value, 17);
      expect(s.contains(FontSets.thai), isTrue);
      expect(s.contains(FontSets.cjk), isFalse);
      expect(s, FontSets.fromInt(17));
      expect(s.hashCode, FontSets.fromInt(17).hashCode);
    });
  });

  // Not fixture-driven: Dart value equality.
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
