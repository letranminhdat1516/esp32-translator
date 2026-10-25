import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/engine/engine_api.g.dart';
import 'package:live_translator/engine/session_machine.dart';
import 'package:live_translator/ui/language_sheet.dart';
import 'package:live_translator/ui/readiness_view.dart';

import 'ui_test_helpers.dart';

LanguagePack pack(String code, String label, String latin) => LanguagePack(
  code: code,
  appleLocale: 'x',
  androidLocale: 'x',
  whisperCode: code,
  label: label,
  labelLatin: latin,
  script: Script.latin,
);

final packs = [
  pack('en', 'English', 'English'),
  pack('ja', '日本語', 'Japanese'),
  pack('fr', 'Français', 'French'),
];

void main() {
  setUpAll(loadTestFont);

  group('LanguageSheet', () {
    testWidgets('lists the packs, ticks the current one, reports the pick', (
      t,
    ) async {
      useIphoneSize(t);
      final picked = <String>[];
      await t.pumpWidget(
        harness(
          Scaffold(
            body: LanguageSheet(
              packs: packs,
              currentCode: 'ja',
              onPick: picked.add,
            ),
          ),
        ),
      );
      expect(find.text('English'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      expect(find.text('Français'), findsOneWidget);
      expect(find.text('Japanese'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('language-ja')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await t.tap(find.text('Français'));
      expect(picked, ['fr']);
    });

    testWidgets('showLanguageSheet closes after a pick', (t) async {
      useIphoneSize(t);
      final picked = <String>[];
      await t.pumpWidget(
        harness(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showLanguageSheet(
                  context,
                  packs: packs,
                  currentCode: 'en',
                  onPick: picked.add,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Ngôn ngữ'), findsOneWidget);
      await t.tap(find.text('Français'));
      await t.pumpAndSettle();
      expect(picked, ['fr']);
      expect(find.text('Ngôn ngữ'), findsNothing);
    });
  });

  group('ReadinessView', () {
    late List<String> calls;
    Future<void> show(
      WidgetTester t,
      SessionState s, {
      double? progress,
    }) async {
      useIphoneSize(t);
      calls = [];
      await t.pumpWidget(
        harness(
          Scaffold(
            body: ReadinessView(
              state: s,
              onDownload: () => calls.add('download'),
              onRetry: () => calls.add('retry'),
              offered: packs,
              onPick: (c) => calls.add('pick $c'),
              labels: const {'en': 'English', 'vi': 'Tiếng Việt'},
              progress: progress,
            ),
          ),
        ),
      );
    }

    testWidgets('NeedsDownload lists every missing item in Vietnamese', (
      t,
    ) async {
      await show(
        t,
        NeedsDownload('en', [
          MissingMsg(kind: MissingKind.speechModel, language: 'en'),
          MissingMsg(
            kind: MissingKind.translation,
            language: 'en',
            from: 'en',
            to: 'vi',
          ),
          MissingMsg(
            kind: MissingKind.translation,
            language: 'en',
            from: 'vi',
            to: 'en',
          ),
          MissingMsg(kind: MissingKind.ttsVoice, language: 'vi'),
        ]),
      );
      expect(find.text('Mô hình nhận giọng'), findsOneWidget);
      expect(find.text('Bản dịch English → Tiếng Việt'), findsOneWidget);
      expect(find.text('Bản dịch Tiếng Việt → English'), findsOneWidget);
      expect(find.text('Giọng đọc tiếng Việt'), findsOneWidget);
      await t.tap(find.text('Tải về'));
      expect(calls, ['download']);
    });

    testWidgets('Downloading shows progress', (t) async {
      await show(t, const Downloading('en'));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Đang tải…'), findsOneWidget);
      await show(t, const Downloading('en'), progress: 0.42);
      await t.pump();
      expect(find.text('Đang tải… 42%'), findsOneWidget);
      expect(
        t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        0.42,
      );
    });

    testWidgets('a failed download shows Thử lại that downloads again', (
      t,
    ) async {
      await show(
        t,
        NeedsDownload('en', [
          MissingMsg(kind: MissingKind.speechModel, language: 'en'),
        ], error: 'timeout'),
      );
      expect(find.text('Chưa tải xong. Kiểm tra mạng rồi thử lại.'), findsOneWidget);
      expect(find.text('timeout'), findsOneWidget);
      await t.tap(find.text('Thử lại'));
      expect(calls, ['download']);
    });

    testWidgets('Failed shows the reason and Thử lại retries', (t) async {
      await show(t, const Failed('en', 'recognizer stopped'));
      expect(find.text('recognizer stopped'), findsOneWidget);
      await t.tap(find.text('Thử lại'));
      expect(calls, ['retry']);
    });

    testWidgets('Choosing lists the packs and reports the pick', (t) async {
      await show(t, const Choosing());
      expect(find.text('Chọn ngôn ngữ'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      await t.tap(find.text('日本語'));
      expect(calls, ['pick ja']);
    });

    testWidgets('Choosing after an unavailable saved language says so', (
      t,
    ) async {
      await show(t, const Choosing(reason: 'unavailable'));
      expect(find.textContaining('không còn dùng được'), findsOneWidget);
    });

    testWidgets('Checking and Preparing show a spinner', (t) async {
      await show(t, const Checking('en'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await show(t, const Preparing('en'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
