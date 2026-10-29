import 'package:live_translator/engine/engine_api.g.dart';
import 'package:live_translator/engine/session_machine.dart';

import '../shared_fixtures.dart';

/// JSON form of the session machine values used by
/// shared/fixtures/session_machine.json.

/// Every state type and event type, in the order of session_machine.dart.
const stateTypes = [
  'loading', 'choosing', 'checking', 'needsDownload', 'downloading',
  'preparing', 'running', 'switching', 'failed',
];
const eventTypes = [
  'catalogReady', 'picked', 'checked', 'downloadTapped', 'downloadDone',
  'downloadFailed', 'started', 'startFailed', 'recognizerDied', 'retry',
];

List<MissingMsg> missingOf(Object? json) => [
  for (final m in json as List)
    MissingMsg(
      kind: MissingKind.values.byName((m as Map)['kind'] as String),
      language: m['language'] as String,
      from: m['from'] as String?,
      to: m['to'] as String?,
    ),
];

List<Map<String, dynamic>> missingJson(List<MissingMsg> missing) => [
  for (final m in missing)
    {
      'kind': m.kind.name,
      'language': m.language,
      if (m.from != null) 'from': m.from,
      if (m.to != null) 'to': m.to,
    },
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

Map<String, dynamic> stateJson(SessionState s) => switch (s) {
  Loading() => {'type': 'loading'},
  Choosing(:final reason) => {'type': 'choosing', 'reason': reason},
  Checking(:final code) => {'type': 'checking', 'code': code},
  NeedsDownload(:final code, :final missing, :final error) => {
    'type': 'needsDownload',
    'code': code,
    'missing': missingJson(missing),
    'error': error,
  },
  Downloading(:final code) => {'type': 'downloading', 'code': code},
  Preparing(:final code, :final restarts) => {'type': 'preparing', 'code': code, 'restarts': restarts},
  Running(:final code, :final restarts) => {'type': 'running', 'code': code, 'restarts': restarts},
  Switching(:final from, :final to) => {'type': 'switching', 'from': from, 'to': to},
  Failed(:final code, :final reason) => {'type': 'failed', 'code': code, 'reason': reason},
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
