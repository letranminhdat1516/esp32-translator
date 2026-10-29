import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/engine/session_machine.dart';

import '../shared_fixtures.dart';
import 'session_json.dart';

/// Writes the "matrix" of shared/fixtures/session_machine.json from the Dart
/// machine: every state type x every event type, with representative
/// values. Not part of the suite (no `_test` suffix); run it after changing
/// session_machine.dart:
///
///     flutter test test/engine/session_matrix_generator.dart
///
/// session_machine_test.dart then asserts the matrix against the machine.
const representativeStates = <Map<String, dynamic>>[
  {'type': 'loading'},
  {'type': 'choosing', 'reason': null},
  {'type': 'checking', 'code': 'ja'},
  {
    'type': 'needsDownload',
    'code': 'ja',
    'missing': [
      {'kind': 'speechModel', 'language': 'ja'},
    ],
    'error': null,
  },
  {'type': 'downloading', 'code': 'ja'},
  {'type': 'preparing', 'code': 'ja', 'restarts': 0},
  {'type': 'running', 'code': 'ja', 'restarts': 0},
  {'type': 'switching', 'from': 'ja', 'to': 'fr'},
  {'type': 'failed', 'code': 'ja', 'reason': 'x'},
];

const representativeEvents = <Map<String, dynamic>>[
  {'type': 'catalogReady', 'saved': 'ja', 'offered': ['ja', 'fr']},
  {'type': 'picked', 'code': 'fr'},
  {'type': 'checked', 'missing': <Object>[]},
  {'type': 'downloadTapped'},
  {'type': 'downloadDone'},
  {'type': 'downloadFailed', 'error': 'offline'},
  {'type': 'started'},
  {'type': 'startFailed', 'reason': 'boom'},
  {'type': 'recognizerDied'},
  {'type': 'retry'},
];

void main() {
  test('write the session matrix', () {
    final path = '$sharedDir/fixtures/session_machine.json';
    final fixture = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    fixture['matrix'] = [
      for (final s in representativeStates)
        for (final e in representativeEvents)
          () {
            final before = stateOf(s);
            final after = next(before, eventOf(e));
            return {
              'name': '${s['type']} + ${e['type']}${after == before ? ' (unchanged)' : ''}',
              'state': s,
              'event': e,
              'expected': stateJson(after),
            };
          }(),
    ];
    File(path).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
  });
}
