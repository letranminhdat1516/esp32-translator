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

/// The cases of [group] in a fixture, as JSON objects (absent -> empty).
List<Map<String, dynamic>> casesOf(Map<String, dynamic> fixture, String group) =>
    [for (final c in (fixture[group] as List?) ?? const []) c as Map<String, dynamic>];

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
