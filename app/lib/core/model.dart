import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Writing system a language is displayed in; decides which board font set
/// is needed ([FontSets.covers]).
enum Script { latin, cjk, hangul, thai, cyrillic, other }

/// Thrown by [LanguagePack.parse] when a pack is malformed. [field] is the
/// path of the offending field, e.g. `label` or `recognition[0].pattern`.
class PackError implements Exception {
  const PackError(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String toString() => 'PackError($field): $reason';
}

/// Bit mask of the glyph sets the board firmware has fonts for.
@immutable
class FontSets {
  const FontSets._(this.value);

  /// Builds a set from a raw bitmask (e.g. the BLE `fontSets` u32).
  const FontSets.fromInt(int value) : this._(value);

  /// Bit 1: Basic Latin plus the Vietnamese letters and tone marks.
  static const latinVI = FontSets._(1);

  /// Bit 2: Latin Extended-A, U+0100-U+017F, in addition to [latinVI].
  static const latinExtA = FontSets._(2);

  /// Bit 4: CJK ideographs plus Japanese kana.
  static const cjk = FontSets._(4);

  /// Bit 8: Korean Hangul syllables.
  static const hangul = FontSets._(8);

  /// Bit 16: Thai.
  static const thai = FontSets._(16);

  final int value;

  FontSets operator |(FontSets other) => FontSets._(value | other.value);

  /// True when every bit of [other] is set in this set.
  bool contains(FontSets other) => (value & other.value) == other.value;

  /// True when the board can render text written in [script].
  /// Cyrillic and other scripts have no board font and are never covered.
  bool covers(Script script) {
    switch (script) {
      case Script.latin:
        return contains(latinVI) || contains(latinExtA);
      case Script.cjk:
        return contains(cjk);
      case Script.hangul:
        return contains(hangul);
      case Script.thai:
        return contains(thai);
      case Script.cyrillic:
      case Script.other:
        return false;
    }
  }

  @override
  bool operator ==(Object other) => other is FontSets && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FontSets($value)';
}

@immutable
class Rule {
  const Rule({
    required this.id,
    required this.pattern,
    required this.template,
    this.atClauseStart = false,
    this.context,
  });

  final String id;
  final String pattern;
  final String template;
  final bool atClauseStart;
  final String? context;

  factory Rule.fromJson(Map<String, dynamic> json, String path) {
    final rule = Rule(
      id: _str(json, 'id', path),
      pattern: _str(json, 'pattern', path),
      template: _str(json, 'template', path),
      atClauseStart: _opt<bool>(json, 'atClauseStart', path) ?? false,
      context: _opt<String>(json, 'context', path),
    );
    _checkRegex(rule.pattern, '$path.pattern');
    if (rule.context != null) _checkRegex(rule.context!, '$path.context');
    return rule;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pattern': pattern,
    'template': template,
    'atClauseStart': atClauseStart,
    if (context != null) 'context': context,
  };

  @override
  bool operator ==(Object other) =>
      other is Rule &&
      other.id == id &&
      other.pattern == pattern &&
      other.template == template &&
      other.atClauseStart == atClauseStart &&
      other.context == context;

  @override
  int get hashCode =>
      Object.hash(id, pattern, template, atClauseStart, context);
}

enum TermOrigin { builtIn, user }

@immutable
class Term {
  const Term({
    required this.id,
    required this.text,
    this.variants = const [],
    this.fixed = const {},
    this.origin = TermOrigin.user,
  });

  final String id;
  final String text;
  final List<String> variants;

  /// Fixed translation per target language code.
  final Map<String, String> fixed;
  final TermOrigin origin;

  factory Term.fromJson(Map<String, dynamic> json, String path) {
    final originName = _opt<String>(json, 'origin', path);
    final TermOrigin origin;
    if (originName == null) {
      origin = TermOrigin.user;
    } else {
      origin =
          TermOrigin.values.asNameMap()[originName] ??
          (throw PackError('$path.origin', 'unknown origin "$originName"'));
    }
    final fixed = _opt<Map>(json, 'fixed', path) ?? const {};
    return Term(
      id: _str(json, 'id', path),
      text: _str(json, 'text', path),
      variants: _strList(json, 'variants', path),
      fixed: {
        for (final e in fixed.entries)
          _fixedKey(e.key, path): _fixedVal(e.value, path),
      },
      origin: origin,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'variants': variants,
    'fixed': fixed,
    'origin': origin.name,
  };

  @override
  bool operator ==(Object other) =>
      other is Term &&
      other.id == id &&
      other.text == text &&
      listEquals(other.variants, variants) &&
      mapEquals(other.fixed, fixed) &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(
    id,
    text,
    Object.hashAll(variants),
    Object.hashAllUnordered(
      fixed.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    origin,
  );
}

@immutable
class LanguagePack {
  const LanguagePack({
    required this.code,
    required this.appleLocale,
    required this.androidLocale,
    required this.whisperCode,
    required this.label,
    required this.labelLatin,
    required this.script,
    this.minConfidence,
    this.recognition = const [],
    this.beforeTranslation = const [],
    this.terms = const [],
    this.hints = const [],
  });

  final String code;
  final String appleLocale;
  final String androidLocale;
  final String whisperCode;
  final String label;
  final String labelLatin;
  final Script script;
  final double? minConfidence;
  final List<Rule> recognition;
  final List<Rule> beforeTranslation;
  final List<Term> terms;
  final List<String> hints;

  /// Parses and validates pack JSON. Throws [PackError] on a missing or
  /// mistyped field, or a regex that does not compile.
  static LanguagePack parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw PackError('', 'invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PackError('', 'pack must be a JSON object');
    }
    return LanguagePack.fromJson(decoded);
  }

  factory LanguagePack.fromJson(Map<String, dynamic> json) {
    final scriptName = _str(json, 'script', '');
    final script =
        Script.values.asNameMap()[scriptName] ??
        (throw PackError('script', 'unknown script "$scriptName"'));
    final conf = _opt<num>(json, 'minConfidence', '');
    return LanguagePack(
      code: _str(json, 'code', ''),
      appleLocale: _str(json, 'appleLocale', ''),
      androidLocale: _str(json, 'androidLocale', ''),
      whisperCode: _str(json, 'whisperCode', ''),
      label: _str(json, 'label', ''),
      labelLatin: _str(json, 'labelLatin', ''),
      script: script,
      minConfidence: conf?.toDouble(),
      recognition: _objList(json, 'recognition', Rule.fromJson),
      beforeTranslation: _objList(json, 'beforeTranslation', Rule.fromJson),
      terms: _objList(json, 'terms', Term.fromJson),
      hints: _strList(json, 'hints', ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'appleLocale': appleLocale,
    'androidLocale': androidLocale,
    'whisperCode': whisperCode,
    'label': label,
    'labelLatin': labelLatin,
    'script': script.name,
    'minConfidence': minConfidence,
    'recognition': [for (final r in recognition) r.toJson()],
    'beforeTranslation': [for (final r in beforeTranslation) r.toJson()],
    'terms': [for (final t in terms) t.toJson()],
    'hints': hints,
  };

  @override
  bool operator ==(Object other) =>
      other is LanguagePack &&
      other.code == code &&
      other.appleLocale == appleLocale &&
      other.androidLocale == androidLocale &&
      other.whisperCode == whisperCode &&
      other.label == label &&
      other.labelLatin == labelLatin &&
      other.script == script &&
      other.minConfidence == minConfidence &&
      listEquals(other.recognition, recognition) &&
      listEquals(other.beforeTranslation, beforeTranslation) &&
      listEquals(other.terms, terms) &&
      listEquals(other.hints, hints);

  @override
  int get hashCode => Object.hash(
    code,
    appleLocale,
    androidLocale,
    whisperCode,
    label,
    labelLatin,
    script,
    minConfidence,
    Object.hashAll(recognition),
    Object.hashAll(beforeTranslation),
    Object.hashAll(terms),
    Object.hashAll(hints),
  );
}

enum RecognizerKind { osOnDevice, whisper, osOnline }

@immutable
class Capabilities {
  const Capabilities({
    required this.recognizers,
    required this.translatable,
    required this.vietnameseVoice,
  });

  /// Recognizers available per language code.
  final Map<String, List<RecognizerKind>> recognizers;

  /// Language codes the device can translate to or from.
  final Set<String> translatable;
  final bool vietnameseVoice;

  @override
  bool operator ==(Object other) =>
      other is Capabilities &&
      other.vietnameseVoice == vietnameseVoice &&
      setEquals(other.translatable, translatable) &&
      other.recognizers.length == recognizers.length &&
      recognizers.entries.every((e) {
        final o = other.recognizers[e.key];
        return o != null && listEquals(o, e.value);
      });

  @override
  int get hashCode => Object.hash(
    vietnameseVoice,
    Object.hashAllUnordered(translatable),
    Object.hashAllUnordered(
      recognizers.entries.map(
        (e) => Object.hash(e.key, Object.hashAll(e.value)),
      ),
    ),
  );
}

@immutable
class BoardInfo {
  const BoardInfo({required this.protocolVersion, required this.fontSets});

  final int protocolVersion;
  final FontSets fontSets;

  @override
  bool operator ==(Object other) =>
      other is BoardInfo &&
      other.protocolVersion == protocolVersion &&
      other.fontSets == fontSets;

  @override
  int get hashCode => Object.hash(protocolVersion, fontSets);
}

// --- JSON helpers -------------------------------------------------------

String _fixedKey(Object? k, String path) =>
    k is String ? k : throw PackError('$path.fixed', 'keys must be strings');

String _fixedVal(Object? v, String path) =>
    v is String ? v : throw PackError('$path.fixed', 'values must be strings');

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

String _str(Map<String, dynamic> json, String key, String path) {
  final v = json[key];
  if (v == null) throw PackError(_join(path, key), 'missing');
  if (v is! String) throw PackError(_join(path, key), 'must be a string');
  return v;
}

T? _opt<T>(Map<String, dynamic> json, String key, String path) {
  final v = json[key];
  if (v == null) return null;
  if (v is! T) throw PackError(_join(path, key), 'must be a $T');
  return v;
}

List<String> _strList(Map<String, dynamic> json, String key, String path) {
  final v = _opt<List>(json, key, path);
  if (v == null) return const [];
  return [
    for (final e in v)
      e is String
          ? e
          : throw PackError(_join(path, key), 'entries must be strings'),
  ];
}

List<T> _objList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>, String) parse,
) {
  final v = _opt<List>(json, key, '');
  if (v == null) return const [];
  return [
    for (var i = 0; i < v.length; i++)
      v[i] is Map<String, dynamic>
          ? parse(v[i] as Map<String, dynamic>, '$key[$i]')
          : throw PackError('$key[$i]', 'must be an object'),
  ];
}

void _checkRegex(String pattern, String field) {
  try {
    RegExp(pattern, unicode: true);
  } on FormatException catch (e) {
    throw PackError(field, 'invalid regex: ${e.message}');
  }
}
