import 'package:flutter/material.dart';

import 'core/model.dart';
import 'ui/conversation_screen.dart';
import 'ui/conversation_state.dart';
import 'ui/glossary_screen.dart';
import 'ui/language_sheet.dart';
import 'ui/theme.dart';

void main() {
  runApp(const DemoApp());
}

/// Demo shell: shows the "Phụ đề" conversation screen with sample state so
/// `flutter run` displays the design. The real controller replaces the state
/// and the actions in Phase 2.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key, this.fontFamily});

  /// Null in the app; widget tests pass a real font (the default test font has no Vietnamese).
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phụ đề',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(fontFamily: fontFamily),
      home: const DemoHome(),
    );
  }
}

class DemoHome extends StatefulWidget {
  const DemoHome({super.key});

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  static final _now = DateTime.now();
  static final _packs = [
    for (final (code, label, latin) in [
      ('en', 'English', 'English'),
      ('ja', '日本語', 'Japanese'),
      ('fr', 'Français', 'French'),
    ])
      LanguagePack(
        code: code,
        appleLocale: code,
        androidLocale: code,
        whisperCode: code,
        label: label,
        labelLatin: latin,
        script: Script.latin,
      ),
  ];

  var _code = 'en';
  var _glossary = <Term>[const Term(id: '1', text: 'Zorvik')];
  late ConversationUiState _state = ConversationUiState(
    phase: UiPhase.running,
    board: BoardState.ready,
    languageLabel: 'English',
    theirLines: [
      UiLine(
        id: 't1',
        source: 'Where is the train station?',
        target: 'Ga tàu ở đâu vậy?',
        at: _now.subtract(const Duration(seconds: 30)),
      ),
      UiLine(
        id: 't2',
        source: 'mumble mumble',
        target: 'lầm bầm gì đó',
        unclear: true,
        at: _now.subtract(const Duration(seconds: 5)),
      ),
    ],
    myLines: [
      UiLine(
        id: 'm1',
        source: 'Đi thẳng rồi rẽ phải nhé',
        target: 'Go straight, then turn right.',
        at: _now.subtract(const Duration(seconds: 15)),
      ),
    ],
    theirPartial: 'and how far is it',
  );

  void _set(ConversationUiState Function(ConversationUiState s) f) =>
      setState(() => _state = f(_state));

  ConversationUiState _copy(
    ConversationUiState s, {
    bool? listening,
    bool? boardMicOn,
    List<UiLine>? theirLines,
    List<UiLine>? myLines,
    String? theirPartial,
    String? languageLabel,
  }) => ConversationUiState(
    phase: s.phase,
    message: s.message,
    session: s.session,
    board: s.board,
    boardMicOn: boardMicOn ?? s.boardMicOn,
    theirLines: theirLines ?? s.theirLines,
    myLines: myLines ?? s.myLines,
    theirPartial: theirPartial ?? s.theirPartial,
    myPartial: s.myPartial,
    listening: listening ?? s.listening,
    languageLabel: languageLabel ?? s.languageLabel,
    onlineRecognizer: s.onlineRecognizer,
    micRoute: s.micRoute,
  );

  void _openLanguages() {
    showLanguageSheet(
      context,
      packs: _packs,
      currentCode: _code,
      onPick: (code) => _set((s) {
        _code = code;
        return _copy(
          s,
          languageLabel: _packs.firstWhere((p) => p.code == code).label,
        );
      }),
    );
  }

  void _openGlossary() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          builder: (context, setInner) => GlossaryScreen(
            terms: _glossary,
            onAdd: (text) {
              if (text.trim().isEmpty) {
                throw const GlossaryValidationError(GlossaryMessages.empty);
              }
              setInner(
                () => _glossary = [
                  ..._glossary,
                  Term(id: '${_glossary.length + 1}', text: text.trim()),
                ],
              );
            },
            onUpdate: (id, text) {
              if (text.trim().isEmpty) {
                throw const GlossaryValidationError(GlossaryMessages.empty);
              }
              setInner(
                () => _glossary = [
                  for (final t in _glossary)
                    t.id == id ? Term(id: id, text: text.trim()) : t,
                ],
              );
            },
            onDelete: (id) =>
                setInner(() => _glossary = [..._glossary]..removeWhere((t) => t.id == id)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConversationScreen(
      state: _state,
      actions: ConversationActions(
        toggleBoardMic: () =>
            _set((s) => _copy(s, boardMicOn: !s.boardMicOn)),
        startListening: () => _set((s) => _copy(s, listening: true)),
        stopListening: () =>
            _set((s) => _copy(s, listening: false, theirPartial: '')),
        clearHistory: () => _set(
          (s) => _copy(s, theirLines: [], myLines: [], theirPartial: ''),
        ),
        openLanguages: _openLanguages,
        openGlossary: _openGlossary,
        onDownload: () {},
        onRetry: () {},
      ),
    );
  }
}
