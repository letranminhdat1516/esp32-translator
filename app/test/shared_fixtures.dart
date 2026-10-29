import 'dart:convert';
import 'dart:io';

import 'package:live_translator/core/model.dart';

/// Root of the language-neutral data shared with the Swift and TypeScript
/// ports (tests run with `app/` as the working directory).
const sharedDir = '../shared';

/// Reads `shared/fixtures/<name>.json`.
Map<String, dynamic> loadFixture(String name) =>
    jsonDecode(File('$sharedDir/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

/// A fixture that does not have the shape a test expects.
class FixtureError extends Error {
  FixtureError(this.message);

  final String message;

  @override
  String toString() => 'FixtureError: $message';
}

/// The cases of [group] in a fixture, as JSON objects. Throws [FixtureError]
/// when the key is missing or null, so a typo cannot silently skip cases.
List<Map<String, dynamic>> casesOf(Map<String, dynamic> fixture, String group) {
  final list = fixture[group];
  if (list == null) {
    throw FixtureError('missing "$group" (keys: ${fixture.keys.join(', ')})');
  }
  return [for (final c in list as List) c as Map<String, dynamic>];
}

/// Like [casesOf] for a list a case may leave out (absent -> empty).
List<Map<String, dynamic>> optionalCasesOf(Map<String, dynamic> fixture, String group) =>
    fixture[group] == null ? const [] : casesOf(fixture, group);

/// Reads `shared/languages/<code>.json`.
LanguagePack sharedPack(String code) =>
    LanguagePack.parse(File('$sharedDir/languages/$code.json').readAsStringSync());

/// A list of strings from JSON (null -> empty).
List<String> strings(Object? v) => [for (final e in (v as List?) ?? const []) e as String];

/// A string map from JSON (null -> empty).
Map<String, String> stringMap(Object? v) => {
  for (final e in ((v as Map?) ?? const {}).entries) e.key as String: e.value as String,
};

/// Lower-case hex of [bytes] without separators, e.g. `0300586e`.
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Bytes of a hex string; spaces are ignored.
List<int> bytesOf(String hex) {
  final h = hex.replaceAll(' ', '');
  return [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
}

/// A [Term] from its fixture JSON (`id` defaults to `text`, `origin` to user).
Term termOf(Map<String, dynamic> j) => Term.fromJson({'id': j['text'], ...j}, 'term');
