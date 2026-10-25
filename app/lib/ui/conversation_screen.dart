import 'package:flutter/material.dart';

import 'conversation_state.dart';
import 'readiness_view.dart';
import 'theme.dart';

/// "Phụ đề" conversation screen: header (language pair, settings, status
/// line), the stream of lines, and the control bar. Ported 1:1 from
/// `ios/Sources/UI/ContentView.swift`.
class ConversationScreen extends StatelessWidget {
  const ConversationScreen({
    super.key,
    required this.state,
    required this.actions,
  });

  final ConversationUiState state;
  final ConversationActions actions;

  Future<void> _confirmClear(BuildContext context) async {
    // The trash sits next to the listen button: a stray tap must not wipe the
    // conversation.
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Xoá toàn bộ hội thoại?',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (yes == true) actions.clearHistory();
  }

  /// needsDownload without a session is a controller bug: loud in debug, a
  /// spinner in release.
  Widget _missingSession() {
    assert(false, 'UiPhase.needsDownload requires ConversationUiState.session');
    return const Center(
      child: CircularProgressIndicator(color: Palette.muted, strokeWidth: 2),
    );
  }

  bool get _canClear => state.phase == UiPhase.running && state.hasHistory;

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (state.phase) {
      UiPhase.needsDownload => Expanded(
        child: state.session == null
            ? _missingSession()
            : ReadinessView(
                state: state.session!,
                onDownload: actions.onDownload,
                onRetry: actions.onRetry,
                offered: state.offeredPacks,
                onPick: actions.pickLanguage,
                labels: state.languageNames,
                progress: state.downloadProgress,
              ),
      ),
      UiPhase.preparing => Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(
                color: Palette.muted,
                strokeWidth: 2,
              ),
              const SizedBox(height: 16),
              Text(
                state.message,
                style: const TextStyle(color: Palette.muted, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
      UiPhase.failed => Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 48,
                color: Palette.muted,
              ),
              const SizedBox(height: 12),
              const Text(
                'Không khởi động được',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  state.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: Palette.muted),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: actions.onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.accent,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      ),
      UiPhase.idle || UiPhase.running => Expanded(
        child: Column(
          children: [
            Expanded(child: _ConversationView(state: state)),
            _ControlBar(
              state: state,
              actions: actions,
              canClear: _canClear,
              onClear: () => _confirmClear(context),
            ),
          ],
        ),
      ),
    };

    return Scaffold(
      backgroundColor: Palette.ground,
      body: SafeArea(
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Palette.text),
          child: Column(
            children: [
              _Header(
                state: state,
                actions: actions,
                canClear: _canClear,
                onClear: () => _confirmClear(context),
              ),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// Language pair, settings, and one status line: listening, board, chips.
class _Header extends StatelessWidget {
  const _Header({
    required this.state,
    required this.actions,
    required this.canClear,
    required this.onClear,
  });

  final ConversationUiState state;
  final ConversationActions actions;
  final bool canClear;
  final VoidCallback onClear;

  String get _boardText => switch (state.board) {
    BoardState.off => 'Bluetooth đang tắt',
    BoardState.scanning => 'Đang tìm board…',
    BoardState.connecting => 'Đang kết nối…',
    BoardState.ready =>
      state.boardMicOn ? 'Board đã kết nối' : 'Board đã kết nối · mic tắt',
  };

  @override
  Widget build(BuildContext context) {
    final listening = state.listening;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Semantics(
                button: true,
                label: 'Tiếng Việt sang ${state.languageLabel}',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: actions.openLanguages,
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: const ShapeDecoration(
                      color: Palette.surface,
                      shape: StadiumBorder(),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Tiếng Việt', style: _pillStyle),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.swap_horiz,
                          size: 18,
                          color: Palette.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(state.languageLabel, style: _pillStyle),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              PopupMenuButton<int>(
                tooltip: 'Cài đặt',
                color: Palette.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onSelected: (v) {
                  switch (v) {
                    case 0:
                      actions.openLanguages();
                    case 1:
                      actions.openGlossary();
                    case 2:
                      onClear();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 0,
                    child: _MenuRow(Icons.language, 'Ngôn ngữ'),
                  ),
                  const PopupMenuItem(
                    value: 1,
                    child: _MenuRow(Icons.menu_book_outlined, 'Từ điển riêng'),
                  ),
                  PopupMenuItem(
                    value: 2,
                    enabled: canClear,
                    child: _MenuRow(
                      Icons.delete_outline,
                      'Xoá hội thoại',
                      color: canClear ? Colors.redAccent : Palette.faint,
                    ),
                  ),
                ],
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Palette.surface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.settings_outlined,
                    size: 20,
                    color: Palette.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: listening ? Palette.accentLight : Palette.faint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    listening ? 'Đang nghe' : 'Đang chờ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: listening ? Palette.text : Palette.muted,
                    ),
                  ),
                ],
              ),
              Text(
                '· $_boardText',
                style: const TextStyle(fontSize: 13, color: Palette.muted),
              ),
              if (state.onlineRecognizer) const _Chip('online'),
              if (listening && state.micRoute == AudioRoute.phoneMic)
                const _Chip('mic điện thoại'),
            ],
          ),
        ],
      ),
    );
  }
}

const _pillStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: Palette.text,
);

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.text, {this.color = Palette.text});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Text(text, style: TextStyle(color: color, fontSize: 15)),
    ],
  );
}

/// Small outlined tag in the status line.
class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: ShapeDecoration(
      shape: StadiumBorder(
        side: BorderSide(color: Palette.accentLight.withValues(alpha: 0.6)),
      ),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Palette.accentLight,
      ),
    ),
  );
}

class _Entry {
  const _Entry(this.line, this.mine);
  final UiLine line;
  final bool mine;
}

/// Both sides in one stream, oldest first: theirs on the left, yours on the
/// right.
class _ConversationView extends StatefulWidget {
  const _ConversationView({required this.state});
  final ConversationUiState state;

  @override
  State<_ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<_ConversationView> {
  final _controller = ScrollController();

  static List<_Entry> entriesOf(ConversationUiState s) {
    final all = [
      for (final l in s.theirLines) _Entry(l, false),
      for (final l in s.myLines)
        if (l.source.isNotEmpty) _Entry(l, true),
    ];
    // List.sort is not stable: break ties by id so equal times keep an order.
    all.sort((a, b) {
      final c = a.line.at.compareTo(b.line.at);
      return c != 0 ? c : a.line.id.compareTo(b.line.id);
    });
    return all;
  }

  @override
  void initState() {
    super.initState();
    _scrollToEnd(animate: false);
  }

  @override
  void didUpdateWidget(_ConversationView old) {
    super.didUpdateWidget(old);
    final a = old.state;
    final b = widget.state;
    final ea = entriesOf(a);
    final eb = entriesOf(b);
    if (ea.length != eb.length ||
        ea.lastOrNull?.line.target != eb.lastOrNull?.line.target ||
        a.theirPartial != b.theirPartial ||
        a.myPartial != b.myPartial) {
      _scrollToEnd(animate: true);
    }
  }

  void _scrollToEnd({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final end = _controller.position.maxScrollExtent;
      if (animate) {
        _controller.animateTo(
          end,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      } else {
        _controller.jumpTo(end);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final entries = entriesOf(s);
    final empty =
        entries.isEmpty && s.theirPartial.isEmpty && s.myPartial.isEmpty;
    final children = <Widget>[
      if (empty) _EmptyHint(listening: s.listening),
      for (final e in entries)
        _Bubble(
          key: ValueKey(e.line.id),
          label: e.mine ? 'Bạn nói' : 'Họ nói',
          line: e.line,
          mine: e.mine,
        ),
      if (s.theirPartial.isNotEmpty)
        _PartialLine(text: s.theirPartial, mine: false),
      if (s.myPartial.isNotEmpty) _PartialLine(text: s.myPartial, mine: true),
    ];
    return SingleChildScrollView(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 26),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.label,
    required this.line,
    required this.mine,
  });

  final String label;
  final UiLine line;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final align = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final textAlign = mine ? TextAlign.right : TextAlign.left;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Palette.muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              line.source,
              textAlign: textAlign,
              style: const TextStyle(fontSize: 14, color: Palette.muted),
            ),
            if (line.target.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                line.target,
                textAlign: textAlign,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: line.unclear ? Palette.faint : Palette.text,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PartialLine extends StatelessWidget {
  const _PartialLine({required this.text, required this.mine});
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Text(
        text,
        textAlign: mine ? TextAlign.right : TextAlign.left,
        style: const TextStyle(
          fontSize: 14,
          fontStyle: FontStyle.italic,
          color: Palette.faint,
        ),
      ),
    ),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.listening});
  final bool listening;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 120, left: 12, right: 12),
    child: Column(
      children: [
        Text(
          listening ? 'Cứ nói đi' : 'Chạm "Bắt đầu nghe" trước khi nói',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Người đối diện nói vào board, bạn nghe tiếng Việt qua AirPods. '
          'Bạn nói tiếng Việt, họ đọc phụ đề trên board.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Palette.muted),
        ),
      ],
    ),
  );
}

/// Board mic · listen / stop · clear
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.state,
    required this.actions,
    required this.canClear,
    required this.onClear,
  });

  final ConversationUiState state;
  final ConversationActions actions;
  final bool canClear;
  final VoidCallback onClear;

  Widget _round({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onTap,
    Color? ring,
  }) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.4 : 1,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Palette.surface,
              shape: BoxShape.circle,
              border: ring == null ? null : Border.all(color: ring, width: 2),
            ),
            child: Icon(icon, size: 22, color: color),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final micOn = state.boardMicOn;
    final running = state.phase == UiPhase.running;
    final listening = state.listening;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _round(
            icon: micOn ? Icons.mic_none : Icons.mic_off,
            color: micOn ? Palette.text : Palette.muted,
            ring: micOn ? Palette.accent : null,
            label: micOn ? 'Tắt mic của board' : 'Bật mic của board',
            onTap: state.board == BoardState.ready
                ? actions.toggleBoardMic
                : null,
          ),
          Semantics(
            button: true,
            enabled: running,
            excludeSemantics: true,
            label: listening ? 'Dừng nghe' : 'Bắt đầu nghe',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: !running
                  ? null
                  : (listening ? actions.stopListening : actions.startListening),
              child: Opacity(
                opacity: running ? 1 : 0.4,
                child: DecoratedBox(
                  key: const Key('listenButtonBackground'),
                  decoration: ShapeDecoration(
                    color: listening ? Palette.accent : Palette.surface,
                    shape: const StadiumBorder(),
                  ),
                  child: Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The header already says "Đang nghe": the button says
                        // what a tap does.
                        Icon(
                          listening ? Icons.stop : Icons.mic,
                          size: 20,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          listening ? 'Dừng nghe' : 'Bắt đầu nghe',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          _round(
            icon: Icons.delete_outline,
            color: Palette.muted,
            label: 'Xoá hội thoại',
            onTap: canClear ? onClear : null,
          ),
        ],
      ),
    );
  }
}
