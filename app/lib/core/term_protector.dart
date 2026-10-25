import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'model.dart';

/// Text with its protected terms swapped for placeholders, and what each
/// placeholder stands for. Made by [TermProtector.mask].
@immutable
class Masked {
  const Masked._(
    this.text,
    this._outputs,
    this._surfaces,
    this._prefix,
    this._suffix,
  );

  /// The text to translate.
  final String text;

  /// Placeholder number -> text it turns back into.
  final Map<int, String> _outputs;

  /// Placeholder number -> the form found in the source text.
  final Map<int, String> _surfaces;
  final String _prefix;
  final String _suffix;

  /// No term was found: [text] is the input and nothing needs restoring.
  bool get isEmpty => _outputs.isEmpty;

  /// (source form, replacement) of every placeholder; used to repair a
  /// translation that lost its placeholders.
  List<(String, String)> get replacements => [
    for (final e in _outputs.entries) (_surfaces[e.key]!, e.value),
  ];
}

/// Keeps names, brands, places and glossary terms intact through translation
/// (R10): each term found in the source is replaced by a placeholder such as
/// `Zorvik1`, the text is translated, and the placeholders are swapped for the
/// term itself or its fixed translation for the target language.
///
/// Terms (and their variants) are matched literally, longest first, and text
/// already taken by a longer term is never masked again. Latin text matches
/// case-insensitively (the spoken form is kept when restored), other scripts
/// exactly. Terms made of letters or digits only match whole words, except in
/// scripts written without spaces (CJK, kana, Hangul, Thai), where a term may
/// sit inside a longer run of text.
class TermProtector {
  const TermProtector();

  static final _numberSlot = RegExp(r'\{n\}');
  static final _nonLatinLetter = RegExp(r'(?!\p{Script=Latin})\p{L}', unicode: true);
  static final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _unspaced = RegExp(
    r'[฀-๿ᄀ-ᇿ぀-ヿ㄰-㆏㐀-䶿一-鿿가-힣豈-﫿]',
    unicode: true,
  );

  /// Replaces the terms found in [text] with placeholders. [placeholder] holds
  /// `{n}` once, replaced by 1, 2, ... in order of appearance (numbers already
  /// used by the text itself are skipped). [target] picks each term's fixed
  /// translation.
  Masked mask(
    String text,
    List<Term> terms,
    String target, {
    String placeholder = 'Zorvik{n}',
  }) {
    final slots = _numberSlot.allMatches(placeholder).toList();
    if (slots.length != 1) {
      throw ArgumentError.value(placeholder, 'placeholder', 'must contain {n} exactly once');
    }
    final prefix = placeholder.substring(0, slots.single.start);
    final suffix = placeholder.substring(slots.single.end);
    if (prefix.isEmpty && suffix.isEmpty) {
      throw ArgumentError.value(placeholder, 'placeholder', 'must have text around {n}');
    }

    final s = unorm.nfc(text);
    final candidates = <(String, Term)>[];
    final seen = <String>{};
    for (final term in terms) {
      for (final surface in [term.text, ...term.variants]) {
        final c = unorm.nfc(surface);
        if (c.isNotEmpty && seen.add(c)) candidates.add((c, term));
      }
    }
    // Longest first; the sort is not stable, so ties keep their input order.
    final indexed = [for (var i = 0; i < candidates.length; i++) (i, candidates[i])];
    indexed.sort((a, b) {
      final byLength = b.$2.$1.length.compareTo(a.$2.$1.length);
      return byLength != 0 ? byLength : a.$1.compareTo(b.$1);
    });

    final lower = s.toLowerCase();
    final spans = <_Span>[];
    for (final (_, (candidate, term)) in indexed) {
      if (!lower.contains(candidate.toLowerCase())) continue;
      for (final m in _regexFor(candidate).allMatches(s)) {
        if (spans.any((o) => m.start < o.end && o.start < m.end)) continue;
        spans.add(_Span(m.start, m.end, term, m[0]!));
      }
    }
    if (spans.isEmpty) return Masked._(s, const {}, const {}, prefix, suffix);
    spans.sort((a, b) => a.start.compareTo(b.start));

    // Numbers the text already uses ("Zorvik1" typed by the speaker) are
    // skipped, so they cannot be mistaken for a placeholder.
    final taken = _slotRegex(prefix, suffix)
        .allMatches(s)
        .map((m) => int.parse(m[1]!))
        .toSet();
    var next = 0;
    int allocate() {
      do {
        next += 1;
      } while (taken.contains(next));
      return next;
    }

    // One placeholder per fixed translation (all spoken forms of a term share
    // it) or per distinct spoken form.
    final numberByKey = <String, int>{};
    final outputs = <int, String>{};
    final surfaces = <int, String>{};
    final out = StringBuffer();
    var pos = 0;
    for (final span in spans) {
      final fixed = span.term.fixed[target];
      final key = fixed != null ? 'fixed:${span.term.id}' : 'text:${span.matched}';
      final n = numberByKey.putIfAbsent(key, () {
        final n = allocate();
        outputs[n] = fixed ?? span.matched;
        surfaces[n] = span.matched;
        return n;
      });
      out
        ..write(s.substring(pos, span.start))
        ..write('$prefix$n$suffix');
      pos = span.end;
    }
    out.write(s.substring(pos));
    return Masked._(out.toString(), outputs, surfaces, prefix, suffix);
  }

  /// Puts the terms back into [translated]. Returns null when a placeholder
  /// did not survive translation; the caller then translates the unmasked text
  /// and repairs fixed terms where found.
  String? restore(String translated, Masked m) {
    if (m.isEmpty) return translated;
    final found = <int>{};
    final restored = translated.replaceAllMapped(_slotRegex(m._prefix, m._suffix), (match) {
      final n = int.parse(match[1]!);
      final output = m._outputs[n];
      if (output == null) return match[0]!;
      found.add(n);
      return output;
    });
    return found.length == m._outputs.length ? restored : null;
  }

  static RegExp _slotRegex(String prefix, String suffix) => RegExp(
    '${RegExp.escape(prefix)}(\\d+)${RegExp.escape(suffix)}',
    caseSensitive: false,
  );

  static RegExp _regexFor(String candidate) {
    final chars = candidate.characters;
    final first = chars.first;
    final last = chars.last;
    final before = _wordChar.hasMatch(first) && !_unspaced.hasMatch(first)
        ? r'(?<![\p{L}\p{N}])'
        : '';
    final after = _wordChar.hasMatch(last) && !_unspaced.hasMatch(last)
        ? r'(?![\p{L}\p{N}])'
        : '';
    return RegExp(
      '$before${RegExp.escape(candidate)}$after',
      caseSensitive: _nonLatinLetter.hasMatch(candidate),
      unicode: true,
    );
  }
}

class _Span {
  const _Span(this.start, this.end, this.term, this.matched);

  final int start;
  final int end;
  final Term term;
  final String matched;
}
