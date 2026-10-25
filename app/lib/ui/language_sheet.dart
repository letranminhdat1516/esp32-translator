import 'package:flutter/material.dart';

import '../core/model.dart';
import 'theme.dart';

/// Bottom sheet content: the offered languages, the current one ticked.
/// Persisting the pick is the caller's job.
class LanguageSheet extends StatelessWidget {
  const LanguageSheet({
    super.key,
    required this.packs,
    required this.currentCode,
    required this.onPick,
  });

  final List<LanguagePack> packs;
  final String? currentCode;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Ngôn ngữ',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          Flexible(
            child: LanguageList(
              packs: packs,
              currentCode: currentCode,
              onPick: onPick,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [LanguageSheet] as a modal bottom sheet; closes it after a pick.
Future<void> showLanguageSheet(
  BuildContext context, {
  required List<LanguagePack> packs,
  required String? currentCode,
  required ValueChanged<String> onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => LanguageSheet(
      packs: packs,
      currentCode: currentCode,
      onPick: (code) {
        Navigator.of(sheetContext).pop();
        onPick(code);
      },
    ),
  );
}

/// The list itself, shared with the "Chọn ngôn ngữ" step of the readiness view.
class LanguageList extends StatelessWidget {
  const LanguageList({
    super.key,
    required this.packs,
    required this.currentCode,
    required this.onPick,
  });

  final List<LanguagePack> packs;
  final String? currentCode;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        for (final p in packs)
          ListTile(
            key: ValueKey('language-${p.code}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: Text(
              p.label,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            subtitle: p.labelLatin == p.label
                ? null
                : Text(
                    p.labelLatin,
                    style: const TextStyle(fontSize: 14, color: Palette.muted),
                  ),
            trailing: p.code == currentCode
                ? const Icon(Icons.check, color: Palette.accentLight)
                : null,
            onTap: () => onPick(p.code),
          ),
      ],
    );
  }
}
