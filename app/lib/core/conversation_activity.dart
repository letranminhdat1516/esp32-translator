enum ActivityState { idle, active }

enum ActivityEvent {
  /// An audio packet from the board mic (English speech).
  boardAudio,

  /// The wearer started speaking (VoiceGate; only heard while a conversation
  /// holds the mic).
  gateOpen,

  /// The wearer stopped speaking.
  gateClosed,

  /// The app started speaking a translation into the earbuds.
  ttsStart,

  /// The app finished speaking a translation.
  ttsEnd,

  /// A tap: the board mic turned on, or the start control in the app.
  userStart,

  /// The stop control in the app.
  userStop,

  /// The audio session was taken away for good (an interruption that should
  /// not resume).
  stop,

  /// Periodic check of the idle timeout.
  tick,
}

/// What the engine must do with the mic and the audio session.
enum ActivityTransition { start, stop }

/// Decides when the app holds the earbuds mic: only during a conversation.
///
/// While idle the app releases the mic and the audio session, so YouTube,
/// TikTok and music play normally (earbuds in high-quality A2DP). A
/// conversation starts with the board streaming English, a translation to
/// speak, or a tap (board mic or the app). The wearer's voice cannot start
/// one: the earbuds mic is off while idle, so the wearer taps before speaking.
/// `gateOpen` only keeps a running conversation alive. After [idleTimeout]
/// (10 minutes, so pauses in a normal conversation don't drop the wearer's
/// next sentence) with nobody speaking (no board audio, gate closed, nothing
/// being spoken) it ends.
///
/// If the engine cannot take the mic ([startFailed]), the conversation goes
/// back to idle and automatic events don't retry for [retryDelay]; a tap
/// always retries. A stop tap ([ActivityEvent.userStop]) ends the conversation
/// and keeps it off until the next tap: board audio and translations no longer
/// take the mic back by themselves.
///
/// Pure value logic, driven by the conversation controller; time comes in with
/// each event so it is unit-tested.
class ConversationActivity {
  ConversationActivity({
    this.idleTimeout = const Duration(seconds: 600),
    this.retryDelay = const Duration(seconds: 30),
  });

  // DateTime's own limits stand in for Swift's distantPast / distantFuture.
  static final _distantPast = DateTime.fromMillisecondsSinceEpoch(
    -8640000000000000,
    isUtc: true,
  );
  static final _distantFuture = DateTime.fromMillisecondsSinceEpoch(
    8640000000000000,
    isUtc: true,
  );

  final Duration idleTimeout;
  final Duration retryDelay;

  ActivityState _state = ActivityState.idle;
  DateTime _lastSpeech = _distantPast;
  bool _gateIsOpen = false;
  bool _speaking = false;

  /// After a failed start, automatic events don't start a conversation before
  /// this.
  DateTime _noAutoStartUntil = _distantPast;

  ActivityState get state => _state;
  DateTime get lastSpeech => _lastSpeech;
  bool get isActive => _state == ActivityState.active;

  /// Applies one event; returns a transition when the state changes.
  ActivityTransition? handle(ActivityEvent event, DateTime now) {
    switch (event) {
      case ActivityEvent.userStart:
        _noAutoStartUntil = _distantPast;
        return _markSpeech(now);
      case ActivityEvent.boardAudio:
        return _markSpeech(now);
      case ActivityEvent.gateOpen:
        _gateIsOpen = true;
        return _markSpeech(now);
      case ActivityEvent.ttsStart:
        _speaking = true;
        return _markSpeech(now);
      case ActivityEvent.gateClosed:
        _gateIsOpen = false;
        if (_state == ActivityState.active) _lastSpeech = now;
        return null;
      case ActivityEvent.ttsEnd:
        _speaking = false;
        if (_state == ActivityState.active) _lastSpeech = now;
        return null;
      case ActivityEvent.stop:
        return _goIdle();
      case ActivityEvent.userStop:
        _noAutoStartUntil = _distantFuture;
        return _goIdle();
      case ActivityEvent.tick:
        if (_state != ActivityState.active ||
            _gateIsOpen ||
            _speaking ||
            now.difference(_lastSpeech) < idleTimeout) {
          return null;
        }
        return _goIdle();
    }
  }

  /// The engine could not take the mic after [ActivityTransition.start]: back
  /// to idle without a `stop` transition (nothing to release), and no
  /// automatic restart for [retryDelay] so a failing mic isn't retried every
  /// second.
  void startFailed(DateTime now) {
    _state = ActivityState.idle;
    _gateIsOpen = false;
    _speaking = false;
    _noAutoStartUntil = now.add(retryDelay);
  }

  ActivityTransition? _markSpeech(DateTime now) {
    _lastSpeech = now;
    if (_state != ActivityState.idle || now.isBefore(_noAutoStartUntil)) {
      return null;
    }
    _state = ActivityState.active;
    return ActivityTransition.start;
  }

  ActivityTransition? _goIdle() {
    _gateIsOpen = false;
    _speaking = false;
    if (_state != ActivityState.active) return null;
    _state = ActivityState.idle;
    return ActivityTransition.stop;
  }
}
