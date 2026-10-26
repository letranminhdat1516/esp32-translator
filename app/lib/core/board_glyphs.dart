import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'model.dart';

/// The exact code points of the board's partition fonts (CJK, Hangul, Thai).
///
/// Those fonts are subsets, so whole Unicode blocks are not drawable. The
/// lists are generated from the font files by `firmware/tools/gen_glyph_sets.py`
/// into `assets/board_glyphs/<set>.txt`, one `XXXX-YYYY` or `XXXX` per line.
class BoardGlyphSets {
  BoardGlyphSets({
    List<(int, int)> cjk = const [],
    List<(int, int)> hangul = const [],
    List<(int, int)> thai = const [],
  }) : _cjk = _sorted(cjk),
       _hangul = _sorted(hangul),
       _thai = _sorted(thai);

  /// Reads the text of the three list files (see [parseRanges]).
  factory BoardGlyphSets.parse({required String cjk, required String hangul, required String thai}) =>
      BoardGlyphSets(cjk: parseRanges(cjk), hangul: parseRanges(hangul), thai: parseRanges(thai));

  static const _assetDir = 'assets/board_glyphs';

  static BoardGlyphSets? _shared;

  /// The lists the app uses unless a [BoardText] is given others. Throws when
  /// [load] has not completed: a board with an extra font must never be
  /// handled with guessed coverage.
  static BoardGlyphSets get shared =>
      _shared ?? (throw StateError('BoardGlyphSets.load() has not completed'));

  /// Loads the lists from the app assets once; later calls return the same
  /// object. Await it at startup, before the first encode for a board with an
  /// extra font.
  static Future<BoardGlyphSets> load([AssetBundle? bundle]) async {
    final existing = _shared;
    if (existing != null) return existing;
    final b = bundle ?? rootBundle;
    final loaded = BoardGlyphSets.parse(
      cjk: await b.loadString('$_assetDir/cjk.txt'),
      hangul: await b.loadString('$_assetDir/hangul.txt'),
      thai: await b.loadString('$_assetDir/thai.txt'),
    );
    return _shared ??= loaded;
  }

  /// Forgets the loaded lists (tests).
  static void resetShared() => _shared = null;

  final List<(int, int)> _cjk;
  final List<(int, int)> _hangul;
  final List<(int, int)> _thai;

  /// The ranges of the fonts [sets] selects (cjk, hangul and thai bits only).
  List<(int, int)> rangesFor(FontSets sets) => [
    if (sets.contains(FontSets.cjk)) ..._cjk,
    if (sets.contains(FontSets.hangul)) ..._hangul,
    if (sets.contains(FontSets.thai)) ..._thai,
  ];

  /// Parses `XXXX-YYYY` / `XXXX` lines (hex, no prefix). Blank lines and `#`
  /// comments are skipped; anything else throws a [FormatException].
  static List<(int, int)> parseRanges(String text) {
    final out = <(int, int)>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split('-');
      final lo = int.tryParse(parts[0], radix: 16);
      final hi = parts.length == 1 ? lo : (parts.length == 2 ? int.tryParse(parts[1], radix: 16) : null);
      if (lo == null || hi == null || hi < lo) throw FormatException('bad glyph range', line);
      out.add((lo, hi));
    }
    return out;
  }

  static List<(int, int)> _sorted(List<(int, int)> r) =>
      List.unmodifiable([...r]..sort((a, b) => a.$1.compareTo(b.$1)));
}
