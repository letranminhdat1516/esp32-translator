import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/core/rule_engine.dart';

import '../shared_fixtures.dart';

/// Cases: shared/fixtures/rules.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('rules');

  RuleEngine engineOf(Map<String, dynamic> spec) {
    final pack = spec['pack'] as String?;
    if (pack != null) return RuleEngine.forPack(sharedPack(pack));
    List<Rule> rules(String key) => [
      for (final (i, r) in (spec[key] as List).indexed)
        Rule.fromJson(r as Map<String, dynamic>, '$key[$i]'),
    ];
    return RuleEngine(
      recognition: rules('recognition'),
      beforeTranslation: rules('beforeTranslation'),
    );
  }

  final engines = {
    for (final e in (fixture['engines'] as Map<String, dynamic>).entries)
      e.key: engineOf(e.value as Map<String, dynamic>),
  };

  group('rules.json cases', () {
    for (final c in casesOf(fixture, 'cases')) {
      test(c['name'] as String, () {
        final engine = engines[c['engine']]!;
        final input = c['input'] as String;
        final out = switch (c['fn']) {
          'fixRecognition' => engine.fixRecognition(input),
          'forTranslation' => engine.forTranslation(input),
          final fn => throw StateError('unknown fn $fn'),
        };
        expect(out, c['expected']);
      });
    }
  });

  // Not fixture-driven: a property of the bundled pack data.
  test('every bundled rule has a unique id', () {
    final pack = sharedPack('vi');
    final ids = [
      for (final r in [...pack.recognition, ...pack.beforeTranslation]) r.id,
    ];
    expect(ids.toSet().length, ids.length);
    expect(ids, everyElement(isNotEmpty));
  });

  group('adversarial input', () {
    // Timing: the subjects and limits are in the fixture, the clock is here.
    final adv = fixture['adversarial'] as Map<String, dynamic>;
    final minLength = adv['minLength'] as int;
    final subjects = <String, String>{
      for (final s in casesOf(adv, 'subjects'))
        s['name'] as String: () {
          final unit = s['unit'] as String;
          final buf = StringBuffer(s['prefix'] as String);
          while (buf.length < minLength) {
            buf.write(unit);
          }
          return buf.toString();
        }(),
    };
    final engine = engines['vi']!;
    final engineRules = [...engine.recognitionRules, ...engine.beforeRules];
    for (final rule in engineRules) {
      test('${rule.id} finishes under ${adv['maxMsPerRule']} ms on each adversarial string', () {
        for (final MapEntry(key: name, value: text) in subjects.entries) {
          expect(text.length, greaterThanOrEqualTo(minLength), reason: name);
          final sw = Stopwatch()..start();
          rule.context?.hasMatch(text);
          text.replaceAllMapped(rule.regex, (m) => '');
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(adv['maxMsPerRule'] as int),
            reason: '${rule.id} on $name took ${sw.elapsedMilliseconds} ms',
          );
        }
      });
    }

    test('the whole pipeline is fast too', () {
      for (final text in subjects.values) {
        final sw = Stopwatch()..start();
        engine.forTranslation(text);
        expect(sw.elapsedMilliseconds, lessThan(adv['maxMsPipeline'] as int));
      }
    });
  });
}
