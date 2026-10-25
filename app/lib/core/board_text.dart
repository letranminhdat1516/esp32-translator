import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'model.dart';
import 'translit.dart';

/// Makes text safe for the board: every character left is one the board's
/// fonts can draw, given the glyph sets it reports ([FontSets]).
///
/// - Characters in the drawable ranges pass through.
/// - Cyrillic and Greek are transliterated to Latin; with no CJK font
///   Japanese kana becomes romaji.
/// - Latin letters the fonts lack are folded to ASCII (`Ł` -> `L`, `ž` ->
///   `z`), fullwidth and other compatibility forms to their plain
///   equivalents, a few symbols are spelled (`€` -> `EUR`).
/// - Letters of a script with no table and no font (Han, Hangul, Thai,
///   Arabic, ...) give `·`, once per run, so a word with nothing drawable
///   becomes a single `·`. Marks, emoji and other symbols are dropped.
/// - Whitespace and control characters collapse to single spaces.
/// - The result is never empty for non-blank input: when nothing is left it
///   is `·`. Blank input stays blank (there is nothing to show).
class BoardText {
  const BoardText();

  // The canonical ranges (progress.md ruling). latinVI is the firmware's
  // `-r` list; latinExtA adds U+0100-U+017F, which contains the four single
  // Vietnamese letter pairs that latinVI lists on their own.
  static const List<(int, int)> _latinVI = [
    (0x20, 0x7e),
    (0xa0, 0xff),
    (0x102, 0x103),
    (0x110, 0x111),
    (0x128, 0x129),
    (0x168, 0x169),
    (0x1a0, 0x1a1),
    (0x1af, 0x1b0),
    (0x1ea0, 0x1ef9),
    (0x2013, 0x2014),
    (0x2018, 0x201d),
    (0x2026, 0x2026),
  ];
  static const List<(int, int)> _latinExtA = [(0x100, 0x17f)];
  static const List<(int, int)> _cjk = [
    (0x3000, 0x303f),
    (0x3040, 0x30ff),
    (0x4e00, 0x9fff),
    (0xff00, 0xffef),
  ];
  static const List<(int, int)> _hangul = [
    (0x1100, 0x11ff),
    (0x3130, 0x318f),
    (0xac00, 0xd7a3),
  ];
  static const List<(int, int)> _thai = [(0x0e00, 0x0e7f)];

  static const String _dot = '·';

  static final Map<int, List<(int, int)>> _cache = {};

  /// The code point ranges the board can draw with [sets], sorted, ranges
  /// that overlap merged. Latin Basic and the Vietnamese letters are always
  /// included: a board that reports no Latin bit is treated as latinVI.
  List<(int, int)> ranges(FontSets sets) => _cache.putIfAbsent(sets.value, () {
    final all = <(int, int)>[
      ..._latinVI,
      if (sets.contains(FontSets.latinExtA)) ..._latinExtA,
      if (sets.contains(FontSets.cjk)) ..._cjk,
      if (sets.contains(FontSets.hangul)) ..._hangul,
      if (sets.contains(FontSets.thai)) ..._thai,
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in all) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
      } else {
        merged.add(r);
      }
    }
    return List.unmodifiable(merged);
  });

  /// True when the board can draw [codePoint] with [sets].
  bool isDrawable(int codePoint, FontSets sets) {
    for (final (lo, hi) in ranges(sets)) {
      if (codePoint < lo) return false;
      if (codePoint <= hi) return true;
    }
    return false;
  }

  static final _separator = RegExp(r'[\s\u0000-\u001f\u007f-\u009f\u00a0\u2028\u2029]+');
  static final _marksAndInvisibles = RegExp(r'^[\p{M}\p{C}]$', unicode: true);
  static final _letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
  static final _marks = RegExp(r'\p{M}', unicode: true);
  static final _spaces = RegExp(r' {2,}');

  /// [text] as the board can show it.
  String encode(String text, FontSets sets) {
    final source = unorm.nfc(text);
    final words = <String>[];
    for (final word in source.split(_separator)) {
      if (word.isEmpty) continue;
      final encoded = _word(word, sets);
      if (encoded.isNotEmpty) words.add(encoded);
    }
    final out = words.join(' ').replaceAll(_spaces, ' ').trim();
    if (out.isNotEmpty) return out;
    return source.trim().isEmpty ? '' : _dot;
  }

  String _word(String word, FontSets sets) {
    final runes = _compatibilityFolded(word.runes.toList(), sets);

    // A word of capitals keeps its transliteration in capitals ("ЖУК" ->
    // "ZHUK", not "ZhUK").
    final letters = [for (final r in runes) if (hasLetterTable(r)) r];
    final allCaps =
        letters.length >= 2 &&
        letters.every((r) {
          final c = String.fromCharCode(r);
          return c.toLowerCase() != c;
        });

    final parts = <String>[];
    void emit(String s) => parts.add(s);
    void dot() {
      if (parts.isEmpty || parts.last != _dot) parts.add(_dot);
    }

    var i = 0;
    while (i < runes.length) {
      final cp = runes[i];
      final ch = String.fromCharCode(cp);
      i++;
      if (isDrawable(cp, sets)) {
        emit(ch);
        continue;
      }
      final letter = translitLetter(
        cp,
        allCaps: allCaps,
        afterOmicron: i >= 2 && isOmicron(runes[i - 2]),
      );
      if (letter != null) {
        emit(letter);
        continue;
      }
      if (isKana(cp)) {
        final kana = readKana(runes, i - 1);
        if (kana == null) {
          dot();
        } else {
          emit(kana.$1);
          i += kana.$2 - 1;
        }
        continue;
      }
      final spelled = punctuation[ch] ?? latinSpecial(ch) ?? asciiDigit(cp) ?? _foldMarks(ch, sets);
      if (spelled != null) {
        emit(spelled);
        continue;
      }
      if (_marksAndInvisibles.hasMatch(ch)) continue;
      if (_letterOrNumber.hasMatch(ch)) {
        dot();
      }
      // Anything else (symbols, emoji, other punctuation) is dropped.
    }
    return parts.join();
  }

  /// Replaces characters the board cannot draw and no table covers by their
  /// compatibility form (fullwidth letters, ligatures, circled digits,
  /// halfwidth katakana), when that gives something different.
  List<int> _compatibilityFolded(List<int> runes, FontSets sets) {
    final out = <int>[];
    for (final cp in runes) {
      final ch = String.fromCharCode(cp);
      final handled =
          isDrawable(cp, sets) ||
          hasLetterTable(cp) ||
          isKana(cp) ||
          punctuation.containsKey(ch) ||
          latinSpecial(ch) != null ||
          asciiDigit(cp) != null ||
          _foldMarks(ch, sets) != null;
      final compat = handled ? ch : unorm.nfkc(ch);
      out.addAll(compat.runes);
    }
    return out;
  }

  /// A Latin letter with its marks removed, when the result can be drawn
  /// (`ž` -> `z`, `ǎ` -> `a`); null otherwise.
  String? _foldMarks(String ch, FontSets sets) {
    final base = unorm.nfd(ch).replaceAll(_marks, '');
    if (base.isEmpty || base == ch) return null;
    return base.runes.every((r) => isDrawable(r, sets)) ? base : null;
  }
}
