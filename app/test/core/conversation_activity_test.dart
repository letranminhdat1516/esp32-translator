import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/conversation_activity.dart';

import '../shared_fixtures.dart';

final t0 = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000, isUtc: true);

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

/// Cases: shared/fixtures/conversation_activity.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('conversation_activity');
  final defaults = fixture['defaults'] as Map<String, dynamic>;

  test('defaults and event names', () {
    final a = ConversationActivity();
    expect(a.idleTimeout, Duration(milliseconds: defaults['idleTimeoutMs'] as int));
    expect(a.retryDelay, Duration(milliseconds: defaults['retryDelayMs'] as int));
    expect(ActivityEvent.values.map((e) => e.name).toSet(), strings(fixture['events']).toSet());
  });

  for (final c in casesOf(fixture, 'scenarios')) {
    test(c['name'] as String, () {
      final config = {...defaults, ...?(c['config'] as Map<String, dynamic>?)};
      final activity = ConversationActivity(
        idleTimeout: Duration(milliseconds: config['idleTimeoutMs'] as int),
        retryDelay: Duration(milliseconds: config['retryDelayMs'] as int),
      );
      expect(activity.state, ActivityState.idle);
      for (final (i, step) in casesOf(c, 'steps').indexed) {
        final now = at(step['atMs'] as int);
        if (step['startFailed'] == true) {
          activity.startFailed(now);
        } else {
          final got = activity.handle(ActivityEvent.values.byName(step['event'] as String), now);
          expect(got?.name, step['expect'], reason: 'step $i $step');
        }
        if (step['state'] != null) {
          expect(activity.state.name, step['state'], reason: 'state after step $i');
          expect(activity.isActive, step['state'] == 'active');
        }
      }
    });
  }
}
