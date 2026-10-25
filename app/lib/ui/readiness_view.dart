import 'package:flutter/material.dart';

import '../core/model.dart';
import '../engine/engine_api.g.dart' show MissingKind, MissingMsg;
import '../engine/session_machine.dart';
import 'language_sheet.dart';
import 'theme.dart';

/// Renders the part of the session that comes before the conversation:
/// choosing a language, checking, missing downloads, downloading, failure.
class ReadinessView extends StatelessWidget {
  const ReadinessView({
    super.key,
    required this.state,
    required this.onDownload,
    required this.onRetry,
    this.offered = const [],
    this.onPick,
    this.labels = const {},
    this.progress,
  });

  final SessionState state;
  final VoidCallback onDownload;
  final VoidCallback onRetry;

  /// Packs listed while [Choosing].
  final List<LanguagePack> offered;
  final ValueChanged<String>? onPick;

  /// Display name per language code, used in "Bản dịch A → B". A missing
  /// code is shown as is.
  final Map<String, String> labels;

  /// 0..1 while [Downloading]; null when the platform reports none.
  final double? progress;

  String _label(String? code) => code == null ? '' : (labels[code] ?? code);

  /// The Vietnamese name of one missing item.
  String missingText(MissingMsg m) => switch (m.kind) {
    MissingKind.speechModel => 'Mô hình nhận giọng',
    MissingKind.translation =>
      'Bản dịch ${_label(m.from ?? m.language)} → ${_label(m.to)}',
    MissingKind.ttsVoice => 'Giọng đọc tiếng Việt',
  };

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      Choosing(:final reason) => _choosing(reason),
      NeedsDownload() => _needsDownload(state as NeedsDownload),
      Downloading() => _downloading(),
      Failed(:final reason) => _failed(reason),
      Loading() ||
      Checking() ||
      Preparing() ||
      Running() ||
      Switching() => _spinner(),
    };
  }

  Widget _spinner([String? text]) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: Palette.muted, strokeWidth: 2),
        if (text != null) ...[
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Palette.muted)),
        ],
      ],
    ),
  );

  Widget _choosing(String? reason) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chọn ngôn ngữ',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (reason == 'unavailable') ...[
              const SizedBox(height: 6),
              const Text(
                'Ngôn ngữ đã chọn trước đó không còn dùng được trên máy này.',
                style: TextStyle(fontSize: 14, color: Palette.accentLight),
              ),
            ],
          ],
        ),
      ),
      Expanded(
        child: LanguageList(
          packs: offered,
          currentCode: null,
          onPick: onPick ?? (_) {},
        ),
      ),
    ],
  );

  Widget _needsDownload(NeedsDownload s) {
    final failed = s.error != null;
    return _centered(
      children: [
        const Icon(
          Icons.arrow_circle_down_outlined,
          size: 48,
          color: Palette.accentLight,
        ),
        const SizedBox(height: 16),
        const Text(
          'Cần tải về trước khi dùng',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        for (final m in s.missing)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              missingText(m),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: Palette.muted),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Tải một lần, sau đó dịch hoàn toàn trên máy: không cần mạng và '
          'nhanh hơn.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Palette.muted),
        ),
        if (failed) ...[
          const SizedBox(height: 12),
          const Text(
            'Chưa tải xong. Kiểm tra mạng rồi thử lại.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Palette.accentLight),
          ),
          if (s.error!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                s.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Palette.faint),
              ),
            ),
        ],
        const SizedBox(height: 16),
        _primaryButton(failed ? 'Thử lại' : 'Tải về', onDownload),
      ],
    );
  }

  Widget _downloading() => _centered(
    children: [
      SizedBox(
        width: 220,
        child: LinearProgressIndicator(
          value: progress,
          color: Palette.accent,
          backgroundColor: Palette.surface,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        progress == null
            ? 'Đang tải…'
            : 'Đang tải… ${(progress! * 100).round()}%',
        style: const TextStyle(fontSize: 15, color: Palette.muted),
      ),
    ],
  );

  Widget _failed(String reason) => _centered(
    children: [
      const Icon(Icons.warning_amber_rounded, size: 48, color: Palette.muted),
      const SizedBox(height: 16),
      const Text(
        'Không khởi động được',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        reason,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, color: Palette.muted),
      ),
      const SizedBox(height: 16),
      _primaryButton('Thử lại', onRetry),
    ],
  );

  Widget _centered({required List<Widget> children}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  Widget _primaryButton(String text, VoidCallback onTap) => FilledButton(
    onPressed: onTap,
    style: FilledButton.styleFrom(
      backgroundColor: Palette.accent,
      foregroundColor: Colors.white,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
    ),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}
