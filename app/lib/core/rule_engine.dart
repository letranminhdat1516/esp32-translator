import 'package:characters/characters.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'model.dart';

/// A [Rule] with its regular expressions compiled.
class CompiledRule {
  CompiledRule._(this.id, this.regex, this.template, this.context);

  factory CompiledRule(Rule rule) {
    // Whole words only: no letter or digit may touch the match. The patterns
    // in the pack data stay free of bounds; the engine adds them. With
    // `atClauseStart` the match must begin the text or follow , . ! ? (the
    // template gets the punctuation back as $1).
    final start = rule.atClauseStart ? r'(^|[,.!?])\s*' : r'(?<![\p{L}\p{N}])';
    final bounded = '$start(?:${rule.pattern})(?![\\p{L}\\p{N}])';
    final context = rule.context;
    return CompiledRule._(
      rule.id,
      RegExp(bounded, caseSensitive: false, unicode: true),
      rule.template,
      context == null
          ? null
          : RegExp(context, caseSensitive: false, unicode: true),
    );
  }

  final String id;
  final RegExp regex;
  final String template;

  /// The rule applies only when the whole text also matches this (context,
  /// e.g. talk about a price).
  final RegExp? context;

  static final _group = RegExp(r'\$(\d)');

  String _expand(Match m) => template.replaceAllMapped(_group, (g) {
    final n = int.parse(g[1]!);
    return n <= m.groupCount ? (m.group(n) ?? '') : '';
  });

  /// Applies the rule to [text].
  String apply(String text) {
    final ctx = context;
    if (ctx != null && !ctx.hasMatch(text)) return text;
    return text.replaceAllMapped(regex, _expand);
  }
}

/// Applies a language pack's rules, which are data, to text around the
/// recognizer and the translator.
///
/// Two lists, both whole-word and case-insensitive:
/// - `recognition` rules fix what the recognizer mishears (loanwords and brand
///   names it spells as native syllables). Applied to the recognized text
///   itself ([fixRecognition]: shown and translated).
/// - `beforeTranslation` rules rewrite text only for the translator
///   ([forTranslation]): vocatives dropped, service phrases and idioms put in
///   plain words. Never shown.
class RuleEngine {
  RuleEngine({
    required List<Rule> recognition,
    required List<Rule> beforeTranslation,
  }) : recognitionRules = List.unmodifiable(recognition.map(CompiledRule.new)),
       beforeRules = List.unmodifiable(beforeTranslation.map(CompiledRule.new));

  factory RuleEngine.forPack(LanguagePack pack) => RuleEngine(
    recognition: pack.recognition,
    beforeTranslation: pack.beforeTranslation,
  );

  final List<CompiledRule> recognitionRules;
  final List<CompiledRule> beforeRules;

  /// Fixes recognizer mishearings. A pack without recognition rules returns
  /// [text] untouched.
  String fixRecognition(String text) => _apply(recognitionRules, text);

  /// The text given to the translator: recognition fixes, then the
  /// before-translation rules, with the gaps they leave tidied. If the rules
  /// leave no letter at all (only vocatives were spoken) the recognition-fixed
  /// text is kept rather than translating nothing. A pack without
  /// before-translation rules returns [fixRecognition]'s result.
  String forTranslation(String text) {
    final fixed = fixRecognition(text);
    if (beforeRules.isEmpty) return fixed;
    final rewritten = _tidy(_apply(beforeRules, fixed), original: text);
    return _hasLetter.hasMatch(rewritten) ? rewritten : fixed;
  }

  static final _hasLetter = RegExp(r'\p{L}', unicode: true);

  static String _apply(List<CompiledRule> rules, String text) {
    if (rules.isEmpty) return text;
    var s = unorm.nfc(text);
    for (final rule in rules) {
      s = rule.apply(s);
    }
    return s;
  }

  static final _spaces = RegExp(r'\s+', unicode: true);
  static final _spaceBeforePunct = RegExp(r'\s+([,.!?])', unicode: true);
  static final _commaAfterPunct = RegExp(r'([,.!?])[,]+', unicode: true);
  static final _leadingJunk = RegExp(r'^[\s,.!]+', unicode: true);
  static final _trailingSpace = RegExp(r'\s+$', unicode: true);

  /// Removes the gaps and stray punctuation left by deletions, and
  /// capitalizes a sentence start.
  static String _tidy(String text, {required String original}) {
    var s = text
        .replaceAll(_spaces, ' ')
        .replaceAllMapped(_spaceBeforePunct, (m) => m[1]!)
        .replaceAllMapped(_commaAfterPunct, (m) => m[1]!)
        .replaceAll(_leadingJunk, '')
        .replaceAll(_trailingSpace, '');
    if (s.isNotEmpty && original.isNotEmpty) {
      final first = s.characters.first;
      final originalFirst = original.characters.first;
      if (_isLower(first) && _isUpper(originalFirst)) {
        s = first.toUpperCase() + s.characters.skip(1).string;
      }
    }
    return s;
  }

  static bool _isLower(String g) => g.toUpperCase() != g && g.toLowerCase() == g;

  static bool _isUpper(String g) => g.toLowerCase() != g && g.toUpperCase() == g;
}
