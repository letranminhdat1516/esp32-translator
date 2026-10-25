import 'package:flutter/foundation.dart';

import '../board/board_link.dart' show BoardState;
import '../core/model.dart' show LanguagePack;
import '../engine/engine_api.g.dart' show AudioRoute;
import '../engine/session_machine.dart' show SessionState;

export '../board/board_link.dart' show BoardState;
export '../engine/engine_api.g.dart' show AudioRoute;

/// What the conversation screen shows besides the conversation itself
/// (mirrors `ConversationEngine.Phase` of the Swift app).
enum UiPhase {
  /// Not started yet: the screen is shown, listening is disabled.
  idle,

  /// A language pack or model is missing: [ConversationUiState.session]
  /// carries what the readiness view renders.
  needsDownload,

  /// Starting up; [ConversationUiState.message] is the status text.
  preparing,

  /// Ready: listening can start.
  running,

  /// Could not start; [ConversationUiState.message] is the reason.
  failed,
}

/// One line of the conversation (theirs or mine).
@immutable
class UiLine {
  const UiLine({
    required this.id,
    required this.source,
    required this.target,
    required this.at,
    this.unclear = false,
  });

  /// Stable key across rebuilds.
  final String id;
  final String source;
  final String target;

  /// Recognized with low confidence: the translation is shown faint.
  final bool unclear;

  /// When the line was last spoken: orders both sides into one stream.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is UiLine &&
      other.id == id &&
      other.source == source &&
      other.target == target &&
      other.unclear == unclear &&
      other.at == at;

  @override
  int get hashCode => Object.hash(id, source, target, unclear, at);
}

/// Everything `ConversationScreen` reads, as plain immutable data. The phase
/// controller maps the engine onto this (Phase 2).
@immutable
class ConversationUiState {
  const ConversationUiState({
    this.phase = UiPhase.idle,
    this.message = '',
    this.session,
    this.board = BoardState.off,
    this.boardMicOn = true,
    this.theirLines = const [],
    this.myLines = const [],
    this.theirPartial = '',
    this.myPartial = '',
    this.listening = false,
    required this.languageLabel,
    this.onlineRecognizer = false,
    this.micRoute = AudioRoute.headset,
    this.offeredPacks = const [],
    this.languageNames = const {},
    this.downloadProgress,
  });

  final UiPhase phase;

  /// Status text for [UiPhase.preparing], reason for [UiPhase.failed].
  final String message;

  /// Rendered by the readiness view for [UiPhase.needsDownload].
  final SessionState? session;

  final BoardState board;
  final bool boardMicOn;
  final List<UiLine> theirLines;
  final List<UiLine> myLines;
  final String theirPartial;
  final String myPartial;

  /// A conversation is going on.
  final bool listening;

  /// The picked language's label: the header shows "Tiếng Việt ⇄ <label>".
  final String languageLabel;

  /// The recognizer sends audio to the network: shows the "online" chip.
  final bool onlineRecognizer;

  /// Where "my" audio comes from; [AudioRoute.phoneMic] shows the
  /// "mic điện thoại" chip while listening.
  final AudioRoute micRoute;

  /// Languages listed while the session is choosing.
  final List<LanguagePack> offeredPacks;

  /// Display name per language code, including the home language: used in
  /// "Bản dịch A → B".
  final Map<String, String> languageNames;

  /// 0..1 while downloading; null when the platform reports none.
  final double? downloadProgress;

  bool get hasHistory => theirLines.isNotEmpty || myLines.isNotEmpty;
}

/// Callbacks of the conversation screen. The relay is gone (no Claude relay).
@immutable
class ConversationActions {
  const ConversationActions({
    required this.toggleBoardMic,
    required this.startListening,
    required this.stopListening,
    required this.clearHistory,
    required this.openLanguages,
    required this.openGlossary,
    required this.onDownload,
    required this.onRetry,
    required this.pickLanguage,
  });

  final VoidCallback toggleBoardMic;
  final VoidCallback startListening;
  final VoidCallback stopListening;

  /// Called after the user confirmed the dialog.
  final VoidCallback clearHistory;
  final VoidCallback openLanguages;
  final VoidCallback openGlossary;

  /// Download button of the readiness view ([UiPhase.needsDownload]).
  final VoidCallback onDownload;

  /// "Thử lại" of [UiPhase.failed] and of a failed download.
  final VoidCallback onRetry;

  /// A language picked in the readiness view ([SessionState] Choosing).
  final ValueChanged<String> pickLanguage;
}
