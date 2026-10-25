import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'model.dart';

/// Why a glossary change was refused or failed. Each case names the offending
/// field (`text`, `variants[2]`, `fixed.en`) where it has one.
sealed class GlossaryError implements Exception {
  const GlossaryError();
}

/// A term, variant or fixed translation is empty or only blanks.
class EmptyText extends GlossaryError {
  const EmptyText(this.field);

  final String field;

  @override
  String toString() => 'EmptyText($field)';
}

/// A string is longer than [limit] characters.
class TooLong extends GlossaryError {
  const TooLong(this.field, this.limit);

  final String field;
  final int limit;

  @override
  String toString() => 'TooLong($field > $limit)';
}

/// A term has more than [limit] variants.
class TooManyVariants extends GlossaryError {
  const TooManyVariants(this.limit);

  final int limit;

  @override
  String toString() => 'TooManyVariants(> $limit)';
}

/// The glossary already holds [limit] terms.
class TooManyTerms extends GlossaryError {
  const TooManyTerms(this.limit);

  final int limit;

  @override
  String toString() => 'TooManyTerms(> $limit)';
}

/// A string holds a control character or a bidirectional override.
class ForbiddenCharacter extends GlossaryError {
  const ForbiddenCharacter(this.field, this.codePoint);

  final String field;
  final int codePoint;

  @override
  String toString() =>
      'ForbiddenCharacter($field, U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')})';
}

/// [value] is already a term or variant (ignoring case) of another entry.
class DuplicateTerm extends GlossaryError {
  const DuplicateTerm(this.field, this.value);

  final String field;
  final String value;

  @override
  String toString() => 'DuplicateTerm($field: $value)';
}

/// No term has this id.
class UnknownTerm extends GlossaryError {
  const UnknownTerm(this.id);

  final String id;

  @override
  String toString() => 'UnknownTerm($id)';
}

/// The glossary file could not be written; nothing was changed.
class GlossaryWriteError extends GlossaryError {
  const GlossaryWriteError(this.cause);

  final Object cause;

  @override
  String toString() => 'GlossaryWriteError($cause)';
}

/// The user's glossary (R11): a JSON list of [Term] in one file, on the phone
/// only (R17). Limits: 500 terms, 64 characters per term (and per variant and
/// fixed translation), 8 variants; control characters and bidirectional
/// overrides (U+202A-U+202E, U+2066-U+2069) are rejected, and every term or
/// variant is unique ignoring case.
///
/// A file that cannot be read back is renamed to
/// `glossary.corrupt-<yyyyMMdd-HHmmss>.json` beside it and the store starts
/// empty ([recoveredFromCorruption]).
class GlossaryStore {
  GlossaryStore._(this._file, this._clock, this._newId);

  static const maxTerms = 500;
  static const maxLength = 64;
  static const maxVariants = 8;

  /// Reads [file] (it need not exist yet). [clock] and [newId] are injected
  /// for tests.
  static Future<GlossaryStore> open(
    File file, {
    DateTime Function()? clock,
    String Function()? newId,
  }) async {
    final store = GlossaryStore._(file, clock ?? DateTime.now, newId ?? _randomId);
    await store._load();
    return store;
  }

  final File _file;
  final DateTime Function() _clock;
  final String Function() _newId;
  final StreamController<List<Term>> _changes = StreamController.broadcast();

  List<Term> _terms = const [];
  bool _recovered = false;
  Future<void> _queue = Future.value();

  /// The terms, in the order they were added.
  List<Term> get terms => List.unmodifiable(_terms);

  /// True when the file was unreadable at [open] and has been set aside.
  bool get recoveredFromCorruption => _recovered;

  /// The new list after every successful change. Broadcast: any number of
  /// listeners.
  Stream<List<Term>> get changes => _changes.stream;

  /// Adds a term (always [TermOrigin.user]) and returns it with its id.
  Future<Term> add({
    required String text,
    List<String> variants = const [],
    Map<String, String> fixed = const {},
  }) => _serial(() async {
    if (_terms.length >= maxTerms) throw const TooManyTerms(maxTerms);
    final term = _validated(_newId(), text, variants, fixed, ignoring: null);
    await _commit([..._terms, term]);
    return term;
  });

  /// Replaces the term [id].
  Future<Term> update(
    String id, {
    required String text,
    List<String> variants = const [],
    Map<String, String> fixed = const {},
  }) => _serial(() async {
    final index = _terms.indexWhere((t) => t.id == id);
    if (index < 0) throw UnknownTerm(id);
    final term = _validated(id, text, variants, fixed, ignoring: id);
    await _commit([..._terms]..[index] = term);
    return term;
  });

  /// Deletes the term [id].
  Future<void> remove(String id) => _serial(() async {
    if (!_terms.any((t) => t.id == id)) throw UnknownTerm(id);
    await _commit([
      for (final t in _terms)
        if (t.id != id) t,
    ]);
  });

  /// Stops the change stream.
  Future<void> dispose() => _changes.close();

  // --- internals ----------------------------------------------------------

  /// Changes run one after the other, so two quick edits never interleave
  /// their file writes.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Term _validated(
    String id,
    String text,
    List<String> variants,
    Map<String, String> fixed, {
    required String? ignoring,
  }) {
    final cleanText = _check('text', text);
    if (variants.length > maxVariants) throw const TooManyVariants(maxVariants);
    final cleanVariants = [
      for (var i = 0; i < variants.length; i++) _check('variants[$i]', variants[i]),
    ];
    final cleanFixed = <String, String>{};
    for (final e in fixed.entries) {
      final code = e.key.trim();
      if (code.isEmpty) throw const EmptyText('fixed');
      cleanFixed[code] = _check('fixed.$code', e.value);
    }

    final taken = <String>{
      for (final t in _terms)
        if (t.id != ignoring)
          for (final s in [t.text, ...t.variants]) _key(s),
    };
    final surfaces = [cleanText, ...cleanVariants];
    for (var i = 0; i < surfaces.length; i++) {
      if (!taken.add(_key(surfaces[i]))) {
        throw DuplicateTerm(i == 0 ? 'text' : 'variants[${i - 1}]', surfaces[i]);
      }
    }
    return Term(
      id: id,
      text: cleanText,
      variants: cleanVariants,
      fixed: cleanFixed,
      origin: TermOrigin.user,
    );
  }

  static String _key(String s) => unorm.nfc(s).toLowerCase();

  /// Trims [value] and applies the per-string rules.
  static String _check(String field, String value) {
    final s = value.trim();
    if (s.isEmpty) throw EmptyText(field);
    for (final rune in s.runes) {
      if (rune <= 0x1f ||
          (rune >= 0x7f && rune <= 0x9f) ||
          (rune >= 0x202a && rune <= 0x202e) ||
          (rune >= 0x2066 && rune <= 0x2069)) {
        throw ForbiddenCharacter(field, rune);
      }
    }
    if (s.characters.length > maxLength) throw TooLong(field, maxLength);
    return s;
  }

  Future<void> _commit(List<Term> next) async {
    try {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode([for (final t in next) t.toJson()]),
        flush: true,
      );
      await tmp.rename(_file.path);
    } on FileSystemException catch (e) {
      throw GlossaryWriteError(e);
    }
    _terms = List.unmodifiable(next);
    if (!_changes.isClosed) _changes.add(_terms);
  }

  Future<void> _load() async {
    if (!await _file.exists()) return;
    try {
      final decoded = jsonDecode(utf8.decode(await _file.readAsBytes()));
      if (decoded is! List) throw const FormatException('not a list');
      final loaded = <Term>[
        for (var i = 0; i < decoded.length; i++)
          decoded[i] is Map<String, dynamic>
              ? Term.fromJson(decoded[i] as Map<String, dynamic>, '[$i]')
              : throw FormatException('entry $i is not an object'),
      ];
      // The same limits as for typing: a hand-edited file must not get around them.
      if (loaded.length > maxTerms) throw const FormatException('too many terms');
      final seen = <String>{};
      for (final t in loaded) {
        _check('text', t.text);
        if (t.variants.length > maxVariants) throw const FormatException('variants');
        for (final v in t.variants) {
          _check('variants', v);
        }
        for (final v in t.fixed.values) {
          _check('fixed', v);
        }
        for (final s in [t.text, ...t.variants]) {
          if (!seen.add(_key(s))) throw FormatException('duplicate $s');
        }
      }
      _terms = List.unmodifiable(loaded);
    } on FormatException {
      await _setAside();
    } on PackError {
      await _setAside();
    } on GlossaryError {
      await _setAside();
    }
  }

  Future<void> _setAside() async {
    final now = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var target = File('${_file.parent.path}/glossary.corrupt-$stamp.json');
    for (var n = 1; await target.exists(); n++) {
      target = File('${_file.parent.path}/glossary.corrupt-$stamp-$n.json');
    }
    await _file.rename(target.path);
    _terms = const [];
    _recovered = true;
  }

  static String _randomId() {
    final r = Random.secure();
    return [for (var i = 0; i < 8; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}
