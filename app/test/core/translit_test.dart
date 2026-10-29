import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/translit.dart';

import '../shared_fixtures.dart';

/// shared/fixtures/translit.json is lib/core/translit.dart's tables as data.
/// translit.dart is the source of truth; these tests prove the export is
/// exact by probing the public functions over whole Unicode blocks.
void main() {
  final fixture = loadFixture('translit');
  final cyrillic = stringMap(fixture['cyrillic']);
  final greek = stringMap(fixture['greek']);

  String ch(int cp) => String.fromCharCode(cp);

  test('cyrillic: every lower-case letter of U+0400-U+04FF', () {
    for (var cp = 0x400; cp <= 0x4ff; cp++) {
      if (ch(cp).toLowerCase() != ch(cp)) continue;
      expect(translitLetter(cp), cyrillic[ch(cp)], reason: 'U+${cp.toRadixString(16)}');
    }
    expect(cyrillic.keys.every((k) => k.runes.single >= 0x400 && k.runes.single <= 0x4ff), isTrue);
  });

  test('greek: every lower-case letter of U+0370-U+03FF and U+1F00-U+1FFF', () {
    for (final (lo, hi) in [(0x370, 0x3ff), (0x1f00, 0x1fff)]) {
      for (var cp = lo; cp <= hi; cp++) {
        if (ch(cp).toLowerCase() != ch(cp)) continue;
        expect(translitLetter(cp), greek[ch(cp)], reason: 'U+${cp.toRadixString(16)}');
      }
    }
    expect(greek.keys.every((k) => k.runes.single >= 0x370 && k.runes.single <= 0x3ff), isTrue);
  });

  test('no other code point has a letter table', () {
    for (var cp = 0; cp <= 0xffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      final lower = ch(cp).toLowerCase();
      final inTable = cyrillic.containsKey(lower) || greek.containsKey(lower);
      expect(hasLetterTable(cp), inTable, reason: 'U+${cp.toRadixString(16)}');
    }
  });

  test('capitals: first letter or, in an all-caps word, all letters', () {
    final rules = fixture['capitals'] as Map<String, dynamic>;
    for (final c in casesOf(rules, 'cases')) {
      final cp = (c['letter'] as String).runes.single;
      expect(translitLetter(cp, allCaps: c['allCaps'] as bool), c['expected'], reason: '$c');
    }
  });

  test('upsilon after omicron', () {
    final u = fixture['upsilonAfterOmicron'] as Map<String, dynamic>;
    for (final l in strings(u['letters'])) {
      expect(translitLetter(l.runes.single, afterOmicron: true), u['latin']);
    }
    for (final o in strings(u['omicrons'])) {
      expect(isOmicron(o.runes.single), isTrue);
    }
  });

  test('latinSpecial: every code point of the BMP', () {
    final table = stringMap(fixture['latinSpecial']);
    for (var cp = 0; cp <= 0xffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      expect(latinSpecial(ch(cp)), table[ch(cp)], reason: 'U+${cp.toRadixString(16)}');
    }
  });

  test('punctuation', () {
    expect(punctuation, stringMap(fixture['punctuation']));
  });

  test('digits of other scripts: every code point of the BMP', () {
    final zeros = (fixture['digitZeros'] as List).cast<int>();
    for (var cp = 0; cp <= 0xffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      final zero = zeros.where((z) => cp >= z && cp <= z + 9).firstOrNull;
      expect(asciiDigit(cp), zero == null ? null : '${cp - zero}', reason: 'U+${cp.toRadixString(16)}');
    }
  });

  group('kana', () {
    final kana = fixture['kana'] as Map<String, dynamic>;
    final hiragana = stringMap(kana['hiragana']);
    final smallY = stringMap(kana['smallY']);
    final range = (kana['hiraganaRange'] as List).cast<int>();
    final kRange = (kana['katakanaRange'] as List).cast<int>();
    final offset = kana['katakanaOffset'] as int;
    final sokuon = kana['sokuon'] as String;
    final n = kana['n'] as String;

    test('each hiragana alone', () {
      for (var cp = range[0]; cp <= range[1]; cp++) {
        final c = ch(cp);
        final got = readKana([cp], 0);
        if (c == sokuon) {
          expect(got, ('', 1));
        } else if (c == n) {
          expect(got, ('n', 1));
        } else if (smallY.containsKey(c)) {
          expect(got, ('y${smallY[c]}', 1));
        } else if (hiragana.containsKey(c)) {
          expect(got, (hiragana[c], 1), reason: c);
        } else {
          expect(got, isNull, reason: 'U+${cp.toRadixString(16)}');
        }
      }
    });

    test('katakana reads as the hiragana at the offset', () {
      for (var cp = kRange[0]; cp <= kRange[1]; cp++) {
        expect(readKana([cp], 0), readKana([cp - offset], 0), reason: 'U+${cp.toRadixString(16)}');
      }
    });

    test('marks that spell nothing', () {
      for (final m in strings(kana['silent'])) {
        expect(readKana([m.runes.single], 0), ('', 1));
      }
    });

    test('isKana', () {
      final ranges = [for (final r in kana['isKana'] as List) (r as List).cast<int>()];
      for (var cp = 0x3000; cp <= 0x30ff; cp++) {
        expect(isKana(cp), ranges.any((r) => cp >= r[0] && cp <= r[1]), reason: 'U+${cp.toRadixString(16)}');
      }
    });
  });
}
