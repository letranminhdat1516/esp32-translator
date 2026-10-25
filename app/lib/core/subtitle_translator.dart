import 'dart:async';

class _TurnState {
  /// Translation per final phrase; null until translated (then the
  /// placeholder is shown).
  final List<String?> finals = [];
  final List<String> placeholders = [];
  String partialSource = '';
  String partial = '';

  String get text {
    final parts = <String>[
      for (var i = 0; i < finals.length; i++) finals[i] ?? placeholders[i],
      partial,
    ];
    return parts.where((s) => s.isNotEmpty).join(' ');
  }
}

class _FinalJob {
  const _FinalJob(this.turn, this.index, this.text);

  final int turn;
  final int index;
  final String text;
}

/// Live subtitles for the "You say" turns: the translation of what the wearer
/// says, shown under their words.
///
/// Each finalized phrase is translated once, in order, and kept; only the
/// current volatile phrase is re-translated as it changes (latest wins, stale
/// requests are dropped). A turn's translation is the finals' translations
/// followed by the volatile one. Re-translating the whole growing turn on
/// every partial made each request longer the longer you spoke, so the work
/// grew with the square of the turn length and the translator got a single
/// unpunctuated run-on sentence; here every request is one phrase between
/// pauses.
///
/// The translation itself is the injected [translate] function (the engine's
/// translator in the app, a stub in tests). It may throw: that phrase then
/// keeps the translation of its volatile version.
class SubtitleTranslator {
  SubtitleTranslator({
    required this.translate,
    required this.onResult,
    this.log,
  });

  final Future<String> Function(String text) translate;
  final void Function(int turn, String translation) onResult;
  final void Function(String message)? log;

  Map<int, _TurnState> _turns = {};
  final List<_FinalJob> _finalJobs = [];
  ({int turn, String text})? _partialJob;
  bool _running = false;

  /// A finalized phrase of [turn] (text already prepared for the translator).
  void addFinal(String text, {required int turn}) {
    final state = _turns[turn] ?? _TurnState();
    state.finals.add(null);
    // Until its translation arrives, the phrase keeps showing the translation
    // of its volatile version.
    state.placeholders.add(state.partial);
    state.partial = '';
    state.partialSource = '';
    if (_partialJob?.turn == turn) _partialJob = null;
    if (text.isEmpty) {
      // Nothing to translate (e.g. the phrase was only "em ơi").
      state.finals[state.finals.length - 1] = '';
      _turns[turn] = state;
      onResult(turn, state.text);
      return;
    }
    _turns[turn] = state;
    _finalJobs.add(_FinalJob(turn, state.finals.length - 1, text));
    // Keep only the last few turns (late results for older lines are dropped).
    _turns = {
      for (final e in _turns.entries)
        if (e.key > turn - 3) e.key: e.value,
    };
    _run();
  }

  /// Drops every turn and pending request (history cleared).
  void reset() {
    _turns.clear();
    _finalJobs.clear();
    _partialJob = null;
  }

  /// The current volatile phrase of [turn] (empty: none).
  void setPartial(String text, {required int turn}) {
    final state = _turns[turn] ?? _TurnState();
    if (text == state.partialSource) return;
    state.partialSource = text;
    if (text.isEmpty) {
      state.partial = '';
      _partialJob = null;
      _turns[turn] = state;
      onResult(turn, state.text);
      return;
    }
    _turns[turn] = state;
    _partialJob = (turn: turn, text: text);
    _run();
  }

  void _run() {
    if (_running) return;
    _running = true;
    // Starts after the caller's synchronous calls, like a Swift Task: a burst
    // of setPartial/addFinal is seen as a whole (finals first).
    scheduleMicrotask(_loop);
  }

  Future<void> _loop() async {
    try {
      while (true) {
        if (_finalJobs.isNotEmpty) {
          final job = _finalJobs.removeAt(0);
          final translation = await _translated(job.text);
          final state = _turns[job.turn];
          if (state == null || job.index >= state.finals.length) continue;
          state.finals[job.index] = translation ?? state.placeholders[job.index];
          onResult(job.turn, state.text);
        } else if (_partialJob != null) {
          final job = _partialJob!;
          _partialJob = null;
          final translation = await _translated(job.text);
          // Drop it if the phrase changed or was finalized meanwhile.
          final state = _turns[job.turn];
          if (state == null ||
              state.partialSource != job.text ||
              translation == null) {
            continue;
          }
          state.partial = translation;
          onResult(job.turn, state.text);
        } else {
          break;
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<String?> _translated(String text) async {
    try {
      return await translate(text);
    } catch (e) {
      log?.call('translate FAILED (${text.length} chars): $e');
      return null;
    }
  }
}
