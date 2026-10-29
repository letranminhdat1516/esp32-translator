import 'package:flutter_test/flutter_test.dart' hide Retry;
import 'package:live_translator/engine/engine_api.g.dart';
import 'package:live_translator/engine/session_machine.dart';

import '../shared_fixtures.dart';

MissingMsg miss([String lang = 'ja']) =>
    MissingMsg(kind: MissingKind.speechModel, language: lang);

List<MissingMsg> missingOf(Object? json) => [
  for (final m in json as List)
    MissingMsg(
      kind: MissingKind.values.byName((m as Map)['kind'] as String),
      language: m['language'] as String,
      from: m['from'] as String?,
      to: m['to'] as String?,
    ),
];

SessionState stateOf(Map<String, dynamic> j) => switch (j['type']) {
  'loading' => const Loading(),
  'choosing' => Choosing(reason: j['reason'] as String?),
  'checking' => Checking(j['code'] as String),
  'needsDownload' => NeedsDownload(j['code'] as String, missingOf(j['missing']), error: j['error'] as String?),
  'downloading' => Downloading(j['code'] as String),
  'preparing' => Preparing(j['code'] as String, restarts: j['restarts'] as int? ?? 0),
  'running' => Running(j['code'] as String, restarts: j['restarts'] as int? ?? 0),
  'switching' => Switching(j['from'] as String, j['to'] as String),
  'failed' => Failed(j['code'] as String, j['reason'] as String),
  final t => throw StateError('unknown state $t'),
};

SessionEvent eventOf(Map<String, dynamic> j) => switch (j['type']) {
  'catalogReady' => CatalogReady(saved: j['saved'] as String?, offered: strings(j['offered']).toSet()),
  'picked' => Picked(j['code'] as String),
  'checked' => Checked(missingOf(j['missing'])),
  'downloadTapped' => const DownloadTapped(),
  'downloadDone' => const DownloadDone(),
  'downloadFailed' => DownloadFailed(j['error'] as String),
  'started' => const Started(),
  'startFailed' => StartFailed(j['reason'] as String),
  'recognizerDied' => const RecognizerDied(),
  'retry' => const Retry(),
  final t => throw StateError('unknown event $t'),
};

/// Cases: shared/fixtures/session_machine.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('session_machine');

  test('missing kinds', () {
    expect(MissingKind.values.map((k) => k.name), strings(fixture['missingKinds']));
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
