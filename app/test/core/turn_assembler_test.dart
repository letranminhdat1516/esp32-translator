import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/rule_engine.dart';
import 'package:live_translator/core/turn_assembler.dart';

import '../shared_fixtures.dart';

final _t0 = DateTime.utc(2026, 1, 1);

DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

DateTime _atSeconds(double seconds) => _t0.add(Duration(microseconds: (seconds * 1e6).round()));

/// Cases: shared/fixtures/turn_assembler.json, recordings
/// shared/fixtures/*.jsonl (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('turn_assembler');
  final defaults = fixture['defaults'] as Map<String, dynamic>;

  TurnAssembler assemblerOf(Map<String, dynamic> c) {
    final config = {...defaults, ...?(c['config'] as Map<String, dynamic>?)};
    final fixPack = config['fixLoanwords'] as String?;
    final engine = fixPack == null ? null : RuleEngine.forPack(sharedPack(fixPack));
    return TurnAssembler(
      turnGap: Duration(milliseconds: config['turnGapMs'] as int),
      staleGap: Duration(milliseconds: config['staleGapMs'] as int),
      maxCharacters: config['maxCharacters'] as int,
      maxDuration: Duration(milliseconds: config['maxDurationMs'] as int),
      fixLoanwords: engine?.fixRecognition,
    );
  }

  TranscriptEvent eventOf(String kind, String text) => switch (kind) {
    'partial' => PartialText(text),
    'final' => FinalText(text),
    _ => throw StateError('unknown kind $kind'),
  };

  group('scenarios', () {
    for (final c in casesOf(fixture, 'scenarios')) {
      test(c['name'] as String, () {
        final a = assemblerOf(c);
        final ids = <int>{};
        for (final (i, step) in casesOf(c, 'steps').indexed) {
          final why = 'step $i $step';
          if (step['kind'] == 'reset') {
            a.reset();
          } else {
            final change = a.handle(eventOf(step['kind'] as String, step['text'] as String), _at(step['atMs'] as int));
            if (step.containsKey('change')) {
              final want = step['change'] as Map<String, dynamic>?;
              expect(
                change,
                want == null ? isNull : TurnChange(started: want['started'] as bool, finalText: want['finalText'] as String?),
                reason: why,
              );
            }
          }
          if (step.containsKey('turnText')) expect(a.turn?.text, step['turnText'], reason: why);
          if (step['turnIsNull'] == true) expect(a.turn, isNull, reason: why);
          if (a.turn != null) ids.add(a.turn!.id);
          if (c['maxTurnTextLength'] != null) {
            expect(a.turn!.text.length, lessThanOrEqualTo(c['maxTurnTextLength'] as int), reason: why);
          }
        }
        if (c['minDistinctTurns'] != null) expect(ids.length, greaterThanOrEqualTo(c['minDistinctTurns'] as int));
      });
    }
  });

  group('recorded replays', () {
    // Recorded recognizer events (ios/Tools/vi-harness, DictationTranscriber
    // vi-VN, real-time).
    for (final c in casesOf(fixture, 'replays')) {
      test(c['name'] as String, () {
        final a = assemblerOf(c);
        final lines = <int, String>{};
        final order = <int>[];
        final records = File('$sharedDir/fixtures/${c['recording']}').readAsLinesSync();
        for (final line in records.where((l) => l.trim().isNotEmpty)) {
          final d = jsonDecode(line) as Map<String, dynamic>;
          final change = a.handle(eventOf(d['kind'] as String, d['text'] as String), _atSeconds((d['t'] as num).toDouble()));
          final turn = a.turn;
          if (change == null || turn == null) continue;
          if (lines[turn.id] == null) order.add(turn.id);
          lines[turn.id] = turn.text;
        }
        expect([for (final id in order) lines[id]!], strings(c['expectLines']));
      });
    }
  });

  // Not fixture-driven: Dart value equality.
  test('Turn equality is by value', () {
    expect(
      const Turn(id: 1, finals: ['a'], partial: 'b'),
      const Turn(id: 1, finals: ['a'], partial: 'b'),
    );
  });
}
