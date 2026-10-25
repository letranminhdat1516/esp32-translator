import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/turn_assembler.dart';

/// Stand-in for the Vietnamese loanword fixer (the real one is the rule
/// engine's recognition rules, covered in rule_engine_test.dart).
String _fakeFix(String s) => s.replaceAll('giữa lo', 'Zalo');

DateTime _t0() => DateTime.utc(2026, 1, 1);

DateTime _at(DateTime t0, double seconds) =>
    t0.add(Duration(microseconds: (seconds * 1e6).round()));

/// Recorded recognizer events (ios/Tools/vi-harness, DictationTranscriber
/// vi-VN, real-time).
List<(double, TranscriptEvent)> recordedEvents(String name) {
  final lines = File('test/fixtures/$name.jsonl').readAsLinesSync();
  return [
    for (final line in lines.where((l) => l.trim().isNotEmpty))
      () {
        final d = jsonDecode(line) as Map<String, dynamic>;
        final text = d['text'] as String;
        final TranscriptEvent event = d['kind'] == 'final'
            ? FinalText(text)
            : PartialText(text);
        return ((d['t'] as num).toDouble(), event);
      }(),
  ];
}

/// Lines the "You say" panel shows after replaying events.
List<String> replay(List<(double, TranscriptEvent)> events) {
  final assembler = TurnAssembler(fixLoanwords: _fakeFix);
  final lines = <int, String>{};
  final order = <int>[];
  final t0 = _t0();
  for (final (t, e) in events) {
    final change = assembler.handle(e, _at(t0, t));
    final turn = assembler.turn;
    if (change == null || turn == null) continue;
    if (lines[turn.id] == null) order.add(turn.id);
    lines[turn.id] = turn.text;
  }
  return [for (final id in order) lines[id]!];
}

void main() {
  test('does not split a phrase that is still volatile', () {
    // The recognizer went quiet for 2.2 s while a phrase was still volatile (a
    // bystander spoke after the user). The old assembly started a new line
    // there: the first kept the stale volatile text, the second repeated it.
    final events = recordedEvents('split_byst12_s20');
    final lines = replay(events);
    expect(lines.length, 1);
    final last = events.last.$2;
    expect(last, isA<FinalText>());
    expect(lines.first, (last as FinalText).text);
  });

  test('long monologue keeps every word', () {
    // A 42 s monologue with pauses of 0.4-1.9 s: one turn, every finalized
    // word kept, in order.
    final events = recordedEvents('long_monologue');
    final finals = [
      for (final e in events)
        if (e.$2 case FinalText(:final text)) text.trim(),
    ];
    final lines = replay(events);
    expect(lines, [finals.join(' ')]);
    expect(lines.first.split(' ').length, 116);
  });

  test('pause after a final starts a new turn', () {
    final a = TurnAssembler(turnGap: const Duration(seconds: 2));
    final t0 = _t0();
    expect(a.handle(const PartialText('xin chào'), t0)?.started, isTrue);
    expect(
      a.handle(const FinalText('xin chào'), _at(t0, 1))?.finalText,
      'xin chào',
    );
    // 1.5 s later: same turn
    expect(a.handle(const PartialText('anh'), _at(t0, 2.5))?.started, isFalse);
    expect(
      a.handle(const FinalText('anh khỏe không'), _at(t0, 3))?.started,
      isFalse,
    );
    expect(a.turn?.text, 'xin chào anh khỏe không');
    // 2.5 s after the final: new turn
    expect(a.handle(const PartialText('cảm ơn'), _at(t0, 5.5))?.started, isTrue);
    expect(a.turn?.text, 'cảm ơn');
  });

  test('waits for a volatile phrase but not forever', () {
    final a = TurnAssembler(
      turnGap: const Duration(seconds: 2),
      staleGap: const Duration(seconds: 10),
    );
    final t0 = _t0();
    a.handle(const PartialText('một hai'), t0);
    expect(
      a.handle(const PartialText('một hai ba'), _at(t0, 3))?.started,
      isFalse,
    );
    expect(a.handle(const PartialText('bốn'), _at(t0, 14))?.started, isTrue);
  });

  test('empty result clears the volatile text', () {
    final a = TurnAssembler();
    final t0 = _t0();
    a.handle(const FinalText('chào'), t0);
    a.handle(const PartialText('ừm'), _at(t0, 0.5));
    expect(a.handle(const FinalText(''), _at(t0, 1)), isNotNull);
    expect(a.turn?.text, 'chào');
    expect(a.handle(const PartialText(''), _at(t0, 1.2)), isNull);
  });

  test('displayed text has loanwords fixed', () {
    final a = TurnAssembler(fixLoanwords: _fakeFix);
    a.handle(const FinalText('Mình nhắn tin qua giữa lo cho tiện nhé'), _t0());
    expect(a.turn?.text, 'Mình nhắn tin qua Zalo cho tiện nhé');
  });

  test('caps a very long turn', () {
    // Hours of talk without a 2 s pause must not grow one line forever: past
    // 600 characters or 60 s a new turn starts at the next phrase after a final.
    final a = TurnAssembler(
      turnGap: const Duration(seconds: 2),
      maxCharacters: 600,
      maxDuration: const Duration(seconds: 60),
    );
    final t0 = _t0();
    final ids = <int>{};
    for (var i = 0; i < 100; i++) {
      final t = _at(t0, i.toDouble());
      a.handle(PartialText('câu $i'), t);
      a.handle(FinalText('câu số $i hôm nay trời đẹp'), _at(t0, i + 0.5));
      ids.add(a.turn!.id);
      expect(a.turn!.text.length, lessThan(600 + 40));
    }
    expect(ids.length, greaterThanOrEqualTo(2));
  });

  test('reset forgets the turn', () {
    final a = TurnAssembler();
    final t0 = _t0();
    a.handle(const PartialText('xin chào'), t0);
    a.reset();
    expect(a.turn, isNull);
    expect(a.handle(const PartialText('anh'), _at(t0, 0.5))?.started, isTrue);
    expect(a.turn?.text, 'anh');
  });

  test('Turn equality is by value', () {
    expect(
      const Turn(id: 1, finals: ['a'], partial: 'b'),
      const Turn(id: 1, finals: ['a'], partial: 'b'),
    );
  });
}
