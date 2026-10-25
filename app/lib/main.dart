import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetBundle, AssetManifest, rootBundle;

import 'core/model.dart';
import 'ui/conversation_screen.dart';
import 'ui/conversation_state.dart';
import 'ui/glossary_screen.dart';
import 'ui/language_sheet.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DemoApp(packs: await loadDemoPacks()));
}

/// The packs the demo offers, read from `assets/languages/*.json` (no locale
/// literals in code). The home language is the header's fixed "Tiếng Việt",
/// so its pack is not offered as the other language.
Future<List<LanguagePack>> loadDemoPacks([AssetBundle? bundle]) async {
  final b = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final paths = manifest
      .listAssets()
      .where((p) => p.startsWith('assets/languages/') && p.endsWith('.json'))
      .toList()
    ..sort();
  final packs = [
    for (final p in paths) LanguagePack.parse(await b.loadString(p)),
  ];
  return packs.where((p) => p.label != 'Tiếng Việt').toList();
}

/// Demo shell: shows the "Phụ đề" conversation screen with sample state so
/// `flutter run` displays the design. The real controller replaces the state
/// and the actions in Phase 2.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key, required this.packs, this.fontFamily});

  final List<LanguagePack> packs;

  /// Null in the app; widget tests pass a real font (the default test font has no Vietnamese).
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phụ đề',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(fontFamily: fontFamily),
      home: DemoHome(packs: packs),
    );
  }
}

class DemoHome extends StatefulWidget {
  const DemoHome({super.key, required this.packs});

  /// Languages offered in the demo (loaded from assets/languages).
  final List<LanguagePack> packs;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  static final _now = DateTime.now();

  late var _code = widget.packs.first.code;
  var _glossary = <Term>[const Term(id: '1', text: 'Zorvik')];
  late ConversationUiState _state = ConversationUiState(
    phase: UiPhase.running,
    board: BoardState.ready,
    languageLabel: widget.packs.first.label,
    offeredPacks: widget.packs,
    languageNames: {for (final p in widget.packs) p.code: p.label},
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
    offeredPacks: s.offeredPacks,
    languageNames: s.languageNames,
    downloadProgress: s.downloadProgress,
  );

  void _openLanguages() {
    showLanguageSheet(
      context,
      packs: widget.packs,
      currentCode: _code,
      onPick: (code) => _set((s) {
        _code = code;
        return _copy(
          s,
          languageLabel: widget.packs.firstWhere((p) => p.code == code).label,
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
        pickLanguage: (_) {},
      ),
    );
  }
}
