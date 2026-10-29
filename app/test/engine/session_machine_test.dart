import 'package:flutter_test/flutter_test.dart' hide Retry;
import 'package:live_translator/engine/engine_api.g.dart';
import 'package:live_translator/engine/session_machine.dart';

import '../shared_fixtures.dart';
import 'session_json.dart';

MissingMsg miss([String lang = 'ja']) =>
    MissingMsg(kind: MissingKind.speechModel, language: lang);

/// Cases: shared/fixtures/session_machine.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('session_machine');

  test('missing kinds', () {
    expect(MissingKind.values.map((k) => k.name), strings(fixture['missingKinds']));
  });

  group('full matrix', () {
    final matrix = casesOf(fixture, 'matrix');

    test('covers every state type x every event type', () {
      final pairs = {
        for (final c in matrix) '${(c['state'] as Map)['type']} + ${(c['event'] as Map)['type']}',
      };
      expect(pairs, {
        for (final s in stateTypes)
          for (final e in eventTypes) '$s + $e',
      });
      expect(matrix.length, stateTypes.length * eventTypes.length);
    });

    for (final c in matrix) {
      test(c['name'] as String, () {
        final s = stateOf(c['state'] as Map<String, dynamic>);
        expect(next(s, eventOf(c['event'] as Map<String, dynamic>)), stateOf(c['expected'] as Map<String, dynamic>));
      });
    }
  });

  group('transition table', () {
    for (final c in casesOf(fixture, 'transitions')) {
      test(c['name'] as String, () {
        final s = stateOf(c['state'] as Map<String, dynamic>);
        final e = eventOf(c['event'] as Map<String, dynamic>);
        expect(next(s, e), stateOf(c['expected'] as Map<String, dynamic>));
      });
    }
  });

  group('generation', () {
    for (final c in casesOf(fixture, 'generations')) {
      test(c['name'] as String, () {
        final start = c['start'] as Map<String, dynamic>;
        var s = Session(stateOf(start['state'] as Map<String, dynamic>), start['generation'] as int);
        for (final (i, step) in casesOf(c, 'steps').indexed) {
          s = advance(s, eventOf(step['event'] as Map<String, dynamic>));
          expect(s.state, stateOf(step['state'] as Map<String, dynamic>), reason: 'step $i');
          expect(s.generation, step['generation'], reason: 'step $i');
        }
      });
    }
  });

  // Not fixture-driven: Dart value equality.
  group('value equality', () {
    test('NeedsDownload compares missing by fields', () {
      expect(NeedsDownload('ja', [miss()]), NeedsDownload('ja', [miss()]));
      expect(
        NeedsDownload('ja', [miss()]),
        isNot(NeedsDownload('ja', [miss('fr')])),
      );
      expect(
        NeedsDownload('ja', [miss()]).hashCode,
        NeedsDownload('ja', [miss()]).hashCode,
      );
    });
    test('different state types are not equal', () {
      expect(const Preparing('ja'), isNot(const Running('ja')));
      expect(const Running('ja'), isNot(const Running('ja', restarts: 1)));
    });
  });
}
