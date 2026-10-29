import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/board_glyphs.dart';
import 'package:live_translator/core/board_text.dart';
import 'package:live_translator/core/model.dart';

import '../shared_fixtures.dart';

String _glyphFile(String name) => File('$sharedDir/board_glyphs/$name.txt').readAsStringSync();

/// The committed lists, as the apps load them.
final glyphs = BoardGlyphSets.parse(cjk: _glyphFile('cjk'), hangul: _glyphFile('hangul'), thai: _glyphFile('thai'));
final text = BoardText(glyphs);
const vi = FontSets.latinVI;
final viExt = FontSets.latinVI | FontSets.latinExtA;

List<(int, int)> _pairs(Object? json) => [
  for (final r in json as List) ((r as List)[0] as int, r[1] as int),
];

/// The BoardText for a case: its own `glyphs` lists, or the shared ones.
BoardText _textOf(Map<String, dynamic> c) {
  final g = c['glyphs'] as Map<String, dynamic>?;
  if (g == null) return text;
  return BoardText(BoardGlyphSets(cjk: _pairs(g['cjk']), hangul: _pairs(g['hangul']), thai: _pairs(g['thai'])));
}

/// Cases: shared/fixtures/board_text.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('board_text');

  group('ranges', () {
    for (final c in casesOf(fixture, 'ranges')) {
      test(c['name'] as String, () {
        final r = _textOf(c).ranges(FontSets.fromInt(c['fontSets'] as int));
        if (c.containsKey('expected')) expect(r, _pairs(c['expected']));
        if (c.containsKey('sameAs')) expect(r, _textOf(c).ranges(FontSets.fromInt(c['sameAs'] as int)));
        if (c.containsKey('expectedLast')) expect(r.last, _pairs([c['expectedLast']]).single);
        if (c.containsKey('noneFrom')) expect(r.any((x) => x.$1 >= (c['noneFrom'] as int)), isFalse);
      });
    }
  });

  group('isDrawable', () {
    for (final c in casesOf(fixture, 'isDrawable')) {
      test(c['name'] as String, () {
        expect(_textOf(c).isDrawable(c['codePoint'] as int, FontSets.fromInt(c['fontSets'] as int)), c['expected']);
      });
    }
  });

  group('parseRanges', () {
    for (final c in casesOf(fixture, 'parseRanges')) {
      test(c['name'] as String, () {
        if (c['error'] == true) {
          expect(() => BoardGlyphSets.parseRanges(c['input'] as String), throwsFormatException);
        } else {
          expect(BoardGlyphSets.parseRanges(c['input'] as String), _pairs(c['expected']));
        }
      });
    }
  });

  group('encode', () {
    for (final c in casesOf(fixture, 'encode')) {
      test(c['name'] as String, () {
        expect(_textOf(c).encode(c['input'] as String, FontSets.fromInt(c['fontSets'] as int)), c['expected']);
      });
    }
  });

  test('every non-blank sample gives output the board can draw', () {
    final inv = fixture['encodeInvariants'] as Map<String, dynamic>;
    for (final setsValue in (inv['fontSets'] as List).cast<int>()) {
      final sets = FontSets.fromInt(setsValue);
      for (final s in strings(inv['samples'])) {
        final out = text.encode(s, sets);
        expect(out, isNotEmpty, reason: '$s with $sets');
        for (final cp in out.runes) {
          expect(
            cp == 0x20 || text.isDrawable(cp, sets),
            isTrue,
            reason: 'U+${cp.toRadixString(16)} from "$s" with $sets',
          );
        }
        expect(out, out.trim());
        expect(out.contains('  '), isFalse);
      }
    }
  });

  // Not fixture-driven: compares with the firmware source, which the ports
  // do not ship.
  test('the Latin/Vietnamese ranges equal the table in firmware/main/glyphs.c', () {
    final c = File('../firmware/main/glyphs.c').readAsStringSync();
    final table = c.split('/* BEGIN GENERATED').last.split('/* END GENERATED */').first;
    final row = RegExp(r'\{\s*0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*([A-Z_| ]+?)\s*\}');
    final latinVI = <(int, int)>[];
    final latinExt = <(int, int)>[];
    for (final m in row.allMatches(table)) {
      final r = (int.parse(m[1]!, radix: 16), int.parse(m[2]!, radix: 16));
      final sets = m[3]!.split('|').map((e) => e.trim()).toSet();
      expect(
        sets.difference({'FONTSET_LATIN_VI', 'FONTSET_LATIN_EXT_A'}),
        isEmpty,
        reason: 'glyphs.c lists a non-Latin set: ${m[0]}',
      );
      if (sets.contains('FONTSET_LATIN_VI')) latinVI.add(r);
      if (sets.contains('FONTSET_LATIN_EXT_A')) latinExt.add(r);
    }
    expect(latinVI, isNotEmpty);
    // Same coverage, whatever the list is split into.
    bool cInSets(int cp, FontSets sets) {
      final wanted = [
        if (sets.contains(FontSets.latinVI)) ...latinVI,
        if (sets.contains(FontSets.latinExtA)) ...latinExt,
      ];
      return wanted.any((r) => cp >= r.$1 && cp <= r.$2);
    }

    for (final sets in [vi, viExt]) {
      for (var cp = 0; cp < 0x3000; cp++) {
        final dart = text.isDrawable(cp, sets);
        final c = cInSets(cp, sets);
        if (dart != c) fail('U+${cp.toRadixString(16)} differs for $sets: dart=$dart c=$c');
      }
    }
  });
}
