import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'shared_fixtures.dart';

/// `shared/languages` and `shared/board_glyphs` are the data both native apps
/// load; the Flutter app bundles its own copy under `assets/`. They must be
/// byte-identical.
void main() {
  for (final (app, shared) in [
    ('assets/languages', '$sharedDir/languages'),
    ('assets/board_glyphs', '$sharedDir/board_glyphs'),
  ]) {
    test('$shared equals app/$app byte for byte', () {
      List<String> names(String dir) => [
        for (final f in Directory(dir).listSync().whereType<File>()) f.uri.pathSegments.last,
      ]..sort();
      final appNames = names(app);
      expect(appNames, isNotEmpty);
      expect(names(shared), appNames);
      for (final n in appNames) {
        expect(
          File('$shared/$n').readAsBytesSync(),
          File('$app/$n').readAsBytesSync(),
          reason: n,
        );
      }
    });
  }
}
