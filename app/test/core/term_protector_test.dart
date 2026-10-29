import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/term_protector.dart';

import '../shared_fixtures.dart';

/// Cases: shared/fixtures/terms.json (see shared/fixtures/README.md).
void main() {
  const protector = TermProtector();
  final fixture = loadFixture('terms');
  final defaultPlaceholder = fixture['defaultPlaceholder'] as String;

  for (final c in casesOf(fixture, 'cases')) {
    test(c['name'] as String, () {
      final terms = [for (final j in c['terms'] as List) termOf(j as Map<String, dynamic>)];
      Masked run() => protector.mask(
        c['text'] as String,
        terms,
        c['target'] as String,
        placeholder: c['placeholder'] as String? ?? defaultPlaceholder,
      );
      if (c['error'] != null) {
        expect(c['error'], 'invalidPlaceholder');
        expect(run, throwsArgumentError);
        return;
      }
      final m = run();
      expect(m.text, c['masked']);
      if (c['isEmpty'] != null) expect(m.isEmpty, c['isEmpty']);
      for (final r in optionalCasesOf(c, 'restores')) {
        expect(protector.restore(r['translated'] as String, m), r['expected'], reason: r['translated'] as String);
      }
    });
  }
}
