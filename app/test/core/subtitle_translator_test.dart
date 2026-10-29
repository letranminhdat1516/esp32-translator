import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/subtitle_translator.dart';

import '../shared_fixtures.dart';

/// A fake translator: upper-cases the text after a delay and records every
/// request.
class FakeTranslator {
  FakeTranslator({required this.delay, this.failing = const {}});

  final Duration delay;
  final List<String> requests = [];
  final Set<String> failing;

  Future<String> translate(String text) async {
    requests.add(text);
    await Future<void>.delayed(delay);
    if (failing.contains(text)) throw Exception('cancelled');
    return text.toUpperCase();
  }
}

/// Cases: shared/fixtures/subtitle_translator.json (see shared/fixtures/README.md).
/// Waits are real time here; the ports may use fake timers.
void main() {
  final fixture = loadFixture('subtitle_translator');

  for (final c in casesOf(fixture, 'scenarios')) {
    test(c['name'] as String, () async {
      final spec = c['translator'] as Map<String, dynamic>;
      final fake = FakeTranslator(
        delay: Duration(milliseconds: spec['delayMs'] as int),
        failing: strings(spec['failing']).toSet(),
      );
      final byTurn = <int, String>{};
      final st = SubtitleTranslator(
        translate: fake.translate,
        onResult: (turn, text) => byTurn[turn] = text,
      );
      for (final step in casesOf(c, 'steps')) {
        switch (step['op']) {
          case 'partial':
            st.setPartial(step['text'] as String, turn: step['turn'] as int);
          case 'final':
            st.addFinal(step['text'] as String, turn: step['turn'] as int);
          case 'reset':
            st.reset();
          case 'wait':
            await Future<void>.delayed(Duration(milliseconds: step['ms'] as int));
          case final op:
            fail('unknown op $op');
        }
      }
      final want = c['expect'] as Map<String, dynamic>;
      for (final e in ((want['results'] as Map<String, dynamic>?) ?? const {}).entries) {
        expect(byTurn[int.parse(e.key)], e.value, reason: 'turn ${e.key}');
      }
      for (final turn in (want['emptyTurns'] as List?) ?? const []) {
        expect(byTurn[turn] ?? '', '', reason: 'turn $turn');
      }
      for (final r in casesOf(want, 'requestCounts')) {
        final n = fake.requests.where((q) => q == r['text']).length;
        if (r['exactly'] != null) expect(n, r['exactly'], reason: r['text'] as String);
        if (r['max'] != null) expect(n, lessThanOrEqualTo(r['max'] as int), reason: r['text'] as String);
      }
      if (want['maxRequestLength'] != null) {
        final longest = fake.requests.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
        expect(longest, lessThanOrEqualTo(want['maxRequestLength'] as int));
      }
      for (final e in ((want['wordCounts'] as Map<String, dynamic>?) ?? const {}).entries) {
        final words = byTurn[int.parse(e.key)]!.split(' ').where((w) => w.isNotEmpty);
        expect(words.length, e.value);
      }
    });
  }
}
