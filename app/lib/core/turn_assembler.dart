import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// One result of a speech recognizer.
sealed class TranscriptEvent {
  const TranscriptEvent(this.text);

  final String text;
}

/// Volatile result that may still change; each one replaces the previous
/// volatile text.
class PartialText extends TranscriptEvent {
  const PartialText(super.text);
}

/// Finalized phrase, will not change. [confidence] is the mean word confidence
/// (0..1) when the engine reports it.
class FinalText extends TranscriptEvent {
  const FinalText(super.text, {this.confidence});

  final double? confidence;
}

/// A turn is the finalized phrases so far plus the current volatile (partial)
/// text.
@immutable
class Turn {
  const Turn({required this.id, this.finals = const [], this.partial = ''});

  final int id;

  /// Finalized phrases, loanwords fixed.
  final List<String> finals;

  /// Volatile text after the last final, loanwords fixed.
  final String partial;

  String get text => [...finals, partial].where((s) => s.isNotEmpty).join(' ');

  Turn copyWith({List<String>? finals, String? partial}) =>
      Turn(id: id, finals: finals ?? this.finals, partial: partial ?? this.partial);

  @override
  bool operator ==(Object other) =>
      other is Turn &&
      other.id == id &&
      other.partial == partial &&
      listEquals(other.finals, finals);

  @override
  int get hashCode => Object.hash(id, partial, Object.hashAll(finals));
}

/// What one event did to the turn.
@immutable
class TurnChange {
  const TurnChange({this.started = false, this.finalText});

  /// This event opened a new turn.
  final bool started;

  /// A phrase finalized by this event (already appended to `turn.finals`).
  final String? finalText;

  @override
  bool operator ==(Object other) =>
      other is TurnChange &&
      other.started == started &&
      other.finalText == finalText;

  @override
  int get hashCode => Object.hash(started, finalText);
}

/// Builds the "You say" turns from the Vietnamese recognizer's events.
///
/// A turn is the finalized phrases so far plus the current volatile (partial)
/// text. A new turn (a fresh subtitle screen) starts only after the wearer has
/// really paused: the last phrase is final and nothing has arrived for
/// [turnGap]. While a phrase is still volatile the turn never splits, even if
/// the recognizer goes quiet for a while (it often does for 2 s or more in
/// noise before revising a phrase); splitting there left the volatile text in
/// one line and repeated it in the next.
///
/// Time comes in with each event, so it is unit-tested without a clock.
class TurnAssembler {
  TurnAssembler({
    this.turnGap = const Duration(seconds: 2),
    this.staleGap = const Duration(seconds: 10),
    this.maxCharacters = 600,
    this.maxDuration = const Duration(seconds: 60),
    String Function(String text)? fixLoanwords,
  }) : _fixLoanwords = fixLoanwords ?? _identity;

  /// A pause longer than this (after a final phrase) starts a new turn.
  final Duration turnGap;

  /// If a volatile phrase is never finalized, give up waiting after this long.
  final Duration staleGap;

  /// A turn longer than this (characters or time) ends at its next final
  /// phrase, so hours of talk without a pause never grow one line without
  /// bound.
  final int maxCharacters;
  final Duration maxDuration;

  /// Recognition fix-up applied to every event's text (the rule engine's
  /// loanword rules for Vietnamese).
  final String Function(String text) _fixLoanwords;

  Turn? _turn;
  DateTime? _lastEvent;
  DateTime? _turnStart;
  bool _closeTurn = false;
  int _nextId = 1;

  Turn? get turn => _turn;

  static String _identity(String s) => s;

  /// Forget the current turn (history cleared); the next event starts a new
  /// one.
  void reset() {
    _turn = null;
    _closeTurn = false;
  }

  /// Applies one recognizer event; returns null when nothing changed.
  TurnChange? handle(TranscriptEvent event, DateTime now) {
    final text = _fixLoanwords(event.text.trim());

    if (text.isEmpty) {
      // An empty result clears the volatile text (the phrase was dropped or
      // is now final).
      final t = _turn;
      if (t == null || t.partial.isEmpty) return null;
      _turn = t.copyWith(partial: '');
      return const TurnChange();
    }

    var started = false;
    final last = _lastEvent;
    // No earlier event counts as an infinite pause (Swift: distantPast).
    final quiet = last == null ? null : now.difference(last);
    final pending = _turn?.partial.isNotEmpty ?? false;
    if (_turn == null ||
        (!pending && (quiet == null || quiet > turnGap || _closeTurn)) ||
        quiet == null ||
        quiet > staleGap) {
      _turn = Turn(id: _nextId);
      _nextId += 1;
      _turnStart = now;
      _closeTurn = false;
      started = true;
    }
    _lastEvent = now;

    String? finalText;
    switch (event) {
      case PartialText():
        _turn = _turn!.copyWith(partial: text);
      case FinalText():
        _turn = _turn!.copyWith(finals: [..._turn!.finals, text], partial: '');
        finalText = text;
        _closeTurn =
            _turn!.text.characters.length > maxCharacters ||
            now.difference(_turnStart!) > maxDuration;
    }
    return TurnChange(started: started, finalText: finalText);
  }
}
