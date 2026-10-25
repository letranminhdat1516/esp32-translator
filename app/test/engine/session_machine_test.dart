import 'package:flutter_test/flutter_test.dart' hide Retry;
import 'package:live_translator/engine/engine_api.g.dart';
import 'package:live_translator/engine/session_machine.dart';

MissingMsg miss([String lang = 'ja']) =>
    MissingMsg(kind: MissingKind.speechModel, language: lang);

void main() {
  group('transition table', () {
    final cases = <String, (SessionState, SessionEvent, SessionState)>{
      'loading + saved offered -> checking': (
        const Loading(),
        const CatalogReady(saved: 'ja', offered: {'ja', 'fr'}),
        const Checking('ja'),
      ),
      'loading + no saved -> choosing': (
        const Loading(),
        const CatalogReady(offered: {'ja'}),
        const Choosing(),
      ),
      'loading + saved not offered -> choosing(unavailable)': (
        const Loading(),
        const CatalogReady(saved: 'de', offered: {'ja'}),
        const Choosing(reason: 'unavailable'),
      ),
      'choosing + pick -> checking': (
        const Choosing(),
        const Picked('ja'),
        const Checking('ja'),
      ),
      'checking + all present -> preparing': (
        const Checking('ja'),
        const Checked([]),
        const Preparing('ja'),
      ),
      'checking + missing -> needsDownload': (
        const Checking('ja'),
        Checked([miss()]),
        NeedsDownload('ja', [miss()]),
      ),
      'needsDownload + download -> downloading': (
        NeedsDownload('ja', [miss()]),
        const DownloadTapped(),
        const Downloading('ja'),
      ),
      'needsDownload + pick -> checking': (
        NeedsDownload('ja', [miss()]),
        const Picked('fr'),
        const Checking('fr'),
      ),
      'downloading + done -> checking (re-check)': (
        const Downloading('ja'),
        const DownloadDone(),
        const Checking('ja'),
      ),
      'downloading + error -> needsDownload with error': (
        const Downloading('ja'),
        const DownloadFailed('offline'),
        const NeedsDownload('ja', [], error: 'offline'),
      ),
      'preparing + started -> running': (
        const Preparing('ja'),
        const Started(),
        const Running('ja'),
      ),
      'preparing + started keeps restarts': (
        const Preparing('ja', restarts: 1),
        const Started(),
        const Running('ja', restarts: 1),
      ),
      'preparing + startFailed -> failed': (
        const Preparing('ja'),
        const StartFailed('boom'),
        const Failed('ja', 'boom'),
      ),
      'running + pick other -> switching': (
        const Running('ja'),
        const Picked('fr'),
        const Switching('ja', 'fr'),
      ),
      'running + pick same -> unchanged': (
        const Running('ja'),
        const Picked('ja'),
        const Running('ja'),
      ),
      'running + recognizerDied first -> preparing(restarts 1)': (
        const Running('ja'),
        const RecognizerDied(),
        const Preparing('ja', restarts: 1),
      ),
      'running + recognizerDied second -> failed': (
        const Running('ja', restarts: 1),
        const RecognizerDied(),
        const Failed('ja', 'recognizer stopped'),
      ),
      'switching + ready -> preparing(to)': (
        const Switching('ja', 'fr'),
        const Checked([]),
        const Preparing('fr'),
      ),
      'switching + missing -> needsDownload(to)': (
        const Switching('ja', 'fr'),
        Checked([miss('fr')]),
        NeedsDownload('fr', [miss('fr')]),
      ),
      'failed + retry -> checking': (
        const Failed('ja', 'x'),
        const Retry(),
        const Checking('ja'),
      ),
      'failed + pick -> checking': (
        const Failed('ja', 'x'),
        const Picked('fr'),
        const Checking('fr'),
      ),
    };
    cases.forEach((name, c) {
      test(name, () => expect(next(c.$1, c.$2), c.$3));
    });
  });

  group('unlisted events leave state unchanged', () {
    final cases = <String, (SessionState, SessionEvent)>{
      'loading + started': (const Loading(), const Started()),
      'running + downloadDone': (const Running('ja'), const DownloadDone()),
      'downloading + picked': (const Downloading('ja'), const Picked('fr')),
      'choosing + retry': (const Choosing(), const Retry()),
      'failed + recognizerDied': (
        const Failed('ja', 'x'),
        const RecognizerDied(),
      ),
    };
    cases.forEach((name, c) {
      test(name, () => expect(next(c.$1, c.$2), c.$1));
    });
  });

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

  group('generation', () {
    test('increments exactly on entering switching', () {
      var s = const Session(Running('ja'), 0);
      s = advance(s, const Picked('fr'));
      expect(s.state, const Switching('ja', 'fr'));
      expect(s.generation, 1);
      s = advance(s, const Checked([]));
      expect(s.state, const Preparing('fr'));
      expect(s.generation, 1);
      s = advance(s, const Started());
      s = advance(s, const Picked('ko'));
      expect(s.generation, 2);
    });
    test('no increment when pick equals current', () {
      final s = advance(const Session(Running('ja'), 3), const Picked('ja'));
      expect(s.generation, 3);
    });
  });
}
