import 'package:flutter/foundation.dart' show listEquals;

import 'engine_api.g.dart';

/// Session state machine (ARCHITECTURE section 3). Pure and immutable.

sealed class SessionState {
  const SessionState();
}

class Loading extends SessionState {
  const Loading();
  @override
  bool operator ==(Object other) => other is Loading;
  @override
  int get hashCode => (Loading).hashCode;
  @override
  String toString() => 'Loading()';
}

class Choosing extends SessionState {
  const Choosing({this.reason});
  final String? reason;
  @override
  bool operator ==(Object other) => other is Choosing && other.reason == reason;
  @override
  int get hashCode => Object.hash(Choosing, reason);
  @override
  String toString() => 'Choosing(reason: $reason)';
}

class Checking extends SessionState {
  const Checking(this.code);
  final String code;
  @override
  bool operator ==(Object other) => other is Checking && other.code == code;
  @override
  int get hashCode => Object.hash(Checking, code);
  @override
  String toString() => 'Checking($code)';
}

class NeedsDownload extends SessionState {
  const NeedsDownload(this.code, this.missing, {this.error});
  final String code;
  final List<MissingMsg> missing;
  final String? error;
  @override
  bool operator ==(Object other) =>
      other is NeedsDownload &&
      other.code == code &&
      other.error == error &&
      listEquals(other.missing, missing);
  @override
  int get hashCode =>
      Object.hash(NeedsDownload, code, error, Object.hashAll(missing));
  @override
  String toString() => 'NeedsDownload($code, $missing, error: $error)';
}

class Downloading extends SessionState {
  const Downloading(this.code);
  final String code;
  @override
  bool operator ==(Object other) => other is Downloading && other.code == code;
  @override
  int get hashCode => Object.hash(Downloading, code);
  @override
  String toString() => 'Downloading($code)';
}

class Preparing extends SessionState {
  const Preparing(this.code, {this.restarts = 0});
  final String code;
  final int restarts;
  @override
  bool operator ==(Object other) =>
      other is Preparing && other.code == code && other.restarts == restarts;
  @override
  int get hashCode => Object.hash(Preparing, code, restarts);
  @override
  String toString() => 'Preparing($code, restarts: $restarts)';
}

class Running extends SessionState {
  const Running(this.code, {this.restarts = 0});
  final String code;
  final int restarts;
  @override
  bool operator ==(Object other) =>
      other is Running && other.code == code && other.restarts == restarts;
  @override
  int get hashCode => Object.hash(Running, code, restarts);
  @override
  String toString() => 'Running($code, restarts: $restarts)';
}

class Switching extends SessionState {
  const Switching(this.from, this.to);
  final String from;
  final String to;
  @override
  bool operator ==(Object other) =>
      other is Switching && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(Switching, from, to);
  @override
  String toString() => 'Switching($from -> $to)';
}

class Failed extends SessionState {
  const Failed(this.code, this.reason);
  final String code;
  final String reason;
  @override
  bool operator ==(Object other) =>
      other is Failed && other.code == code && other.reason == reason;
  @override
  int get hashCode => Object.hash(Failed, code, reason);
  @override
  String toString() => 'Failed($code, $reason)';
}

sealed class SessionEvent {
  const SessionEvent();
}

class CatalogReady extends SessionEvent {
  const CatalogReady({this.saved, required this.offered});
  final String? saved;
  final Set<String> offered;
}

class Picked extends SessionEvent {
  const Picked(this.code);
  final String code;
}

class Checked extends SessionEvent {
  const Checked(this.missing);
  final List<MissingMsg> missing;
}

class DownloadTapped extends SessionEvent {
  const DownloadTapped();
}

class DownloadDone extends SessionEvent {
  const DownloadDone();
}

class DownloadFailed extends SessionEvent {
  const DownloadFailed(this.error);
  final String error;
}

class Started extends SessionEvent {
  const Started();
}

class StartFailed extends SessionEvent {
  const StartFailed(this.reason);
  final String reason;
}

class RecognizerDied extends SessionEvent {
  const RecognizerDied();
}

class Retry extends SessionEvent {
  const Retry();
}

SessionState _afterCheck(String code, List<MissingMsg> missing) =>
    missing.isEmpty ? Preparing(code) : NeedsDownload(code, missing);

/// Pure transition function. Events not listed for a state leave it unchanged.
SessionState next(SessionState s, SessionEvent e) {
  switch ((s, e)) {
    case (Loading(), CatalogReady(:final saved, :final offered)):
      if (saved == null) return const Choosing();
      return offered.contains(saved)
          ? Checking(saved)
          : const Choosing(reason: 'unavailable');
    case (Choosing() || NeedsDownload() || Failed(), Picked(:final code)):
      return Checking(code);
    case (Checking(:final code), Checked(:final missing)):
      return _afterCheck(code, missing);
    case (NeedsDownload(:final code), DownloadTapped()):
      return Downloading(code);
    case (Downloading(:final code), DownloadDone()):
      // Re-check: one download may not cover every missing item.
      return Checking(code);
    case (Downloading(:final code), DownloadFailed(:final error)):
      return NeedsDownload(code, const [], error: error);
    case (Preparing(:final code, :final restarts), Started()):
      return Running(code, restarts: restarts);
    case (Preparing(:final code), StartFailed(:final reason)):
      return Failed(code, reason);
    case (Running(:final code), Picked(code: final y)):
      return y == code ? s : Switching(code, y);
    case (Running(:final code, :final restarts), RecognizerDied()):
      return restarts == 0
          ? Preparing(code, restarts: 1)
          : Failed(code, 'recognizer stopped');
    case (Switching(:final to), Checked(:final missing)):
      return _afterCheck(to, missing);
    case (Failed(:final code), Retry()):
      return Checking(code);
    default:
      return s;
  }
}

/// A state plus the generation of "their" side; late results carrying an old
/// generation are dropped by the caller.
class Session {
  const Session(this.state, this.generation);
  final SessionState state;
  final int generation;
  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.state == state &&
      other.generation == generation;
  @override
  int get hashCode => Object.hash(state, generation);
  @override
  String toString() => 'Session($state, gen $generation)';
}

/// Applies [e]; increments the generation when a switch begins.
Session advance(Session s, SessionEvent e) {
  final n = next(s.state, e);
  final entered = n is Switching && n != s.state;
  return Session(n, entered ? s.generation + 1 : s.generation);
}
