import 'package:flutter/foundation.dart';

import 'model.dart';
import 'rule_engine.dart';
import 'term_protector.dart';

/// Which way a phrase is translated.
enum Direction {
  /// The wearer speaks the home language; the other language comes out.
  mine,

  /// The other person speaks; the home language comes out.
  theirs,
}

/// A phrase ready for the translator.
@immutable
class Prepared {
  const Prepared._({
    required this.text,
    required this.unmasked,
    required this.targetCode,
    required this.masked,
  });

  /// What to translate: rules applied, protected terms replaced by
  /// placeholders.
  final String text;

  /// The same text with the rules applied and the terms in place (the
  /// fallback request when a placeholder is lost).
  final String unmasked;

  /// Language code the translation is into.
  final String targetCode;

  /// The placeholders and what they stand for.
  final Masked masked;
}

/// Everything done to a phrase around the translator: the source language's
/// rules (recognition fixes, vocatives and idioms rewritten, R9, R13), then
/// protected terms (R10, R11) swapped for placeholders; and the reverse after
/// translation.
///
/// Rules and built-in terms come from the language packs; glossary terms are
/// the user's and win over built-in terms spelled the same. The placeholder
/// shape is pipeline configuration, per target language ([placeholders]), with
/// [defaultPlaceholder] otherwise.
class TextPipeline {
  TextPipeline({
    required this.home,
    required this.other,
    this.glossary = const [],
    this.placeholders = const {},
    this.defaultPlaceholder = 'Zorvik{n}',
  }) : _homeRules = RuleEngine.forPack(home),
       _otherRules = RuleEngine.forPack(other);

  /// The home language (Vietnamese).
  final LanguagePack home;

  /// The language picked for the other person.
  final LanguagePack other;

  final List<Term> glossary;

  /// Placeholder shape per target language code (`{n}` = the number).
  final Map<String, String> placeholders;
  final String defaultPlaceholder;

  final RuleEngine _homeRules;
  final RuleEngine _otherRules;
  final TermProtector _protector = const TermProtector();

  int _lost = 0;

  /// Placeholders lost by the translator so far (the unmasked fallback ran).
  int get lostPlaceholders => _lost;

  /// Prepares [text] for translation in [direction].
  Prepared prepare(String text, Direction direction) {
    final (rules, target) = switch (direction) {
      Direction.mine => (_homeRules, other.code),
      Direction.theirs => (_otherRules, home.code),
    };
    final ruled = rules.forTranslation(text);
    final masked = _protector.mask(
      ruled,
      [...glossary, ...home.terms, ...other.terms],
      target,
      placeholder: placeholders[target] ?? defaultPlaceholder,
    );
    return Prepared._(
      text: masked.text,
      unmasked: ruled,
      targetCode: target,
      masked: masked,
    );
  }

  /// Puts the protected terms back into [translated]. Null when a placeholder
  /// did not survive translation.
  String? finish(String translated, Prepared prepared) =>
      _protector.restore(translated, prepared.masked);

  /// Repairs a translation of the unmasked text: each protected term found as
  /// written in the source (whole words, same case) is replaced by its fixed translation.
  String repair(String translated, Prepared prepared) {
    var out = translated;
    for (final (surface, output) in prepared.masked.replacements) {
      if (surface == output) continue;
      out = out.replaceAll(TermProtector.wholeWordRegex(surface, caseSensitive: true), output);
    }
    return out;
  }

  /// Prepare, translate with the injected [translator], finish. If the
  /// translator drops a placeholder, the unmasked text is translated instead
  /// and fixed terms are repaired where found (counted in
  /// [lostPlaceholders]).
  Future<String> translate(
    String text,
    Direction direction,
    Future<String> Function(String text) translator,
  ) async {
    if (text.trim().isEmpty) return '';
    final prepared = prepare(text, direction);
    final translated = await translator(prepared.text);
    final restored = finish(translated, prepared);
    if (restored != null) return restored;
    _lost += 1;
    return repair(await translator(prepared.unmasked), prepared);
  }
}
