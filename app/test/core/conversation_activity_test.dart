import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/conversation_activity.dart';

final t0 = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000, isUtc: true);

DateTime at(num seconds) =>
    t0.add(Duration(microseconds: (seconds * 1e6).round()));

void main() {
  test('starts idle', () {
    final activity = ConversationActivity();
    expect(activity.state, ActivityState.idle);
    expect(activity.handle(ActivityEvent.tick, at(1000)), isNull);
    expect(activity.handle(ActivityEvent.gateClosed, at(1)), isNull);
    expect(activity.handle(ActivityEvent.ttsEnd, at(1)), isNull);
    expect(activity.handle(ActivityEvent.stop, at(1)), isNull);
    expect(activity.state, ActivityState.idle);
  });

  for (final event in [
    ActivityEvent.boardAudio,
    ActivityEvent.gateOpen,
    ActivityEvent.ttsStart,
    ActivityEvent.userStart,
  ]) {
    test('speech or tap starts a conversation: $event', () {
      final activity = ConversationActivity();
      expect(activity.handle(event, at(0)), ActivityTransition.start);
      expect(activity.state, ActivityState.active);
      // Already active: no second start
      expect(activity.handle(event, at(1)), isNull);
    });
  }

  test('ends after ten minutes of silence', () {
    final activity = ConversationActivity();
    expect(activity.idleTimeout, const Duration(seconds: 600));
    expect(
      activity.handle(ActivityEvent.boardAudio, at(0)),
      ActivityTransition.start,
    );
    expect(activity.handle(ActivityEvent.tick, at(599)), isNull);
    expect(activity.handle(ActivityEvent.tick, at(600)), ActivityTransition.stop);
    expect(activity.state, ActivityState.idle);
    expect(activity.handle(ActivityEvent.tick, at(1500)), isNull);
  });

  test('board audio keeps it alive', () {
    final activity = ConversationActivity();
    activity.handle(ActivityEvent.userStart, at(0));
    activity.handle(ActivityEvent.boardAudio, at(100));
    expect(activity.handle(ActivityEvent.tick, at(650)), isNull);
    expect(activity.handle(ActivityEvent.tick, at(700)), ActivityTransition.stop);
  });

  test('open gate never times out', () {
    final activity = ConversationActivity();
    activity.handle(ActivityEvent.gateOpen, at(0));
    expect(activity.handle(ActivityEvent.tick, at(1000)), isNull);
    // The timeout counts from when the wearer stopped
    activity.handle(ActivityEvent.gateClosed, at(1000));
    expect(activity.handle(ActivityEvent.tick, at(1599)), isNull);
    expect(
      activity.handle(ActivityEvent.tick, at(1600)),
      ActivityTransition.stop,
    );
  });

  test('speaking never times out', () {
    final activity = ConversationActivity();
    expect(
      activity.handle(ActivityEvent.ttsStart, at(0)),
      ActivityTransition.start,
    );
    expect(activity.handle(ActivityEvent.tick, at(1000)), isNull);
    activity.handle(ActivityEvent.ttsEnd, at(1010));
    expect(activity.handle(ActivityEvent.tick, at(1609)), isNull);
    expect(
      activity.handle(ActivityEvent.tick, at(1610)),
      ActivityTransition.stop,
    );
  });

  test('stop ends right away and clears flags', () {
    final activity = ConversationActivity();
    activity.handle(ActivityEvent.gateOpen, at(0));
    activity.handle(ActivityEvent.ttsStart, at(0));
    expect(activity.handle(ActivityEvent.stop, at(1)), ActivityTransition.stop);
    expect(activity.state, ActivityState.idle);
    // A new conversation is not held open by the old gate / speech flags
    expect(
      activity.handle(ActivityEvent.userStart, at(10)),
      ActivityTransition.start,
    );
    expect(activity.handle(ActivityEvent.tick, at(610)), ActivityTransition.stop);
  });

  test('end events while idle do not start or stretch', () {
    final activity = ConversationActivity();
    activity.handle(ActivityEvent.userStart, at(0));
    expect(activity.handle(ActivityEvent.tick, at(600)), ActivityTransition.stop);
    expect(activity.handle(ActivityEvent.gateClosed, at(610)), isNull);
    expect(activity.handle(ActivityEvent.ttsEnd, at(610)), isNull);
    expect(activity.state, ActivityState.idle);
  });

  test('custom timeout', () {
    final activity = ConversationActivity(
      idleTimeout: const Duration(seconds: 5),
    );
    activity.handle(ActivityEvent.userStart, at(0));
    expect(activity.handle(ActivityEvent.tick, at(4.9)), isNull);
    expect(activity.handle(ActivityEvent.tick, at(5)), ActivityTransition.stop);
  });

  test('failed start goes back to idle without stop', () {
    final activity = ConversationActivity();
    activity.handle(ActivityEvent.gateOpen, at(0));
    expect(activity.handle(ActivityEvent.ttsStart, at(0)), isNull);
    activity.startFailed(at(0));
    expect(activity.state, ActivityState.idle);
    expect(activity.isActive, isFalse);
    // Nothing to release: ticks and stops don't report a transition
    expect(activity.handle(ActivityEvent.tick, at(5)), isNull);
    expect(activity.handle(ActivityEvent.stop, at(5)), isNull);
  });

  for (final event in [
    ActivityEvent.boardAudio,
    ActivityEvent.gateOpen,
    ActivityEvent.ttsStart,
  ]) {
    test('failed start holds off automatic retries: $event', () {
      final activity = ConversationActivity(
        retryDelay: const Duration(seconds: 30),
      );
      expect(
        activity.handle(ActivityEvent.boardAudio, at(0)),
        ActivityTransition.start,
      );
      activity.startFailed(at(0));
      expect(activity.handle(event, at(1)), isNull);
      expect(activity.handle(event, at(29.9)), isNull);
      expect(activity.state, ActivityState.idle);
      expect(activity.handle(event, at(30)), ActivityTransition.start);
    });
  }

  test('tap retries right after a failed start', () {
    final activity = ConversationActivity();
    expect(
      activity.handle(ActivityEvent.boardAudio, at(0)),
      ActivityTransition.start,
    );
    activity.startFailed(at(0));
    expect(
      activity.handle(ActivityEvent.userStart, at(1)),
      ActivityTransition.start,
    );
    // A tap clears the hold-off: after another success + end, board audio
    // restarts at once
    expect(activity.handle(ActivityEvent.stop, at(2)), ActivityTransition.stop);
    expect(
      activity.handle(ActivityEvent.boardAudio, at(3)),
      ActivityTransition.start,
    );
  });

  test('flags from a failed start do not hold the next conversation', () {
    final activity = ConversationActivity(retryDelay: Duration.zero);
    activity.handle(ActivityEvent.gateOpen, at(0));
    activity.handle(ActivityEvent.ttsStart, at(0));
    activity.startFailed(at(0));
    expect(
      activity.handle(ActivityEvent.userStart, at(10)),
      ActivityTransition.start,
    );
    expect(activity.handle(ActivityEvent.tick, at(610)), ActivityTransition.stop);
  });

  test('stop tap ends it until the next tap', () {
    final activity = ConversationActivity();
    expect(
      activity.handle(ActivityEvent.userStart, at(0)),
      ActivityTransition.start,
    );
    expect(activity.handle(ActivityEvent.gateOpen, at(1)), isNull);
    expect(
      activity.handle(ActivityEvent.userStop, at(2)),
      ActivityTransition.stop,
    );
    expect(activity.state, ActivityState.idle);
    // Board audio and translations don't take the mic back, even much later
    expect(activity.handle(ActivityEvent.boardAudio, at(3)), isNull);
    expect(activity.handle(ActivityEvent.ttsStart, at(10000)), isNull);
    expect(activity.state, ActivityState.idle);
    expect(
      activity.handle(ActivityEvent.userStart, at(10001)),
      ActivityTransition.start,
    );
  });

  test('stop tap while idle does nothing', () {
    final activity = ConversationActivity();
    expect(activity.handle(ActivityEvent.userStop, at(0)), isNull);
    expect(
      activity.handle(ActivityEvent.userStart, at(1)),
      ActivityTransition.start,
    );
  });
}
