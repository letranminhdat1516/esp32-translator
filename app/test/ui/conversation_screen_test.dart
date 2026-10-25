import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/engine/engine_api.g.dart' show MissingKind, MissingMsg;
import 'package:live_translator/engine/session_machine.dart';
import 'package:live_translator/ui/conversation_screen.dart';
import 'package:live_translator/ui/conversation_state.dart';
import 'package:live_translator/ui/theme.dart';

import 'ui_test_helpers.dart';

class Calls {
  final log = <String>[];
  late final actions = ConversationActions(
    toggleBoardMic: () => log.add('mic'),
    startListening: () => log.add('start'),
    stopListening: () => log.add('stop'),
    clearHistory: () => log.add('clear'),
    openLanguages: () => log.add('languages'),
    openGlossary: () => log.add('glossary'),
    onDownload: () => log.add('download'),
    onRetry: () => log.add('retry'),
    pickLanguage: (c) => log.add('pick $c'),
  );
}

final t0 = DateTime(2026, 10, 26, 10);
UiLine line(String id, String s, String t, int sec, {bool unclear = false}) =>
    UiLine(
      id: id,
      source: s,
      target: t,
      at: t0.add(Duration(seconds: sec)),
      unclear: unclear,
    );

ConversationUiState state({
  UiPhase phase = UiPhase.running,
  bool listening = false,
  List<UiLine> theirs = const [],
  List<UiLine> mine = const [],
  String theirPartial = '',
  String myPartial = '',
  bool online = false,
  AudioRoute route = AudioRoute.headset,
  BoardState board = BoardState.ready,
  bool boardMicOn = true,
  String message = '',
  SessionState? session,
  List<LanguagePack> offered = const [],
  double? progress,
}) => ConversationUiState(
  phase: phase,
  message: message,
  session: session,
  board: board,
  boardMicOn: boardMicOn,
  theirLines: theirs,
  myLines: mine,
  theirPartial: theirPartial,
  myPartial: myPartial,
  listening: listening,
  languageLabel: 'English',
  onlineRecognizer: online,
  micRoute: route,
  offeredPacks: offered,
  languageNames: const {'en': 'English', 'vi': 'Tiếng Việt'},
  downloadProgress: progress,
);

Future<Calls> pump(WidgetTester tester, ConversationUiState s) async {
  useIphoneSize(tester);
  final calls = Calls();
  await tester.pumpWidget(
    harness(ConversationScreen(state: s, actions: calls.actions)),
  );
  return calls;
}

Color? textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  setUpAll(loadTestFont);

  testWidgets('idle: "Bắt đầu nghe" starts, then "Dừng nghe" stops', (t) async {
    final calls = await pump(t, state());
    expect(find.text('Bắt đầu nghe'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsWidgets);
    await t.tap(find.text('Bắt đầu nghe'));
    expect(calls.log, ['start']);

    final calls2 = await pump(t, state(listening: true));
    await t.pump();
    expect(find.text('Dừng nghe'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    final bg = t.widget<DecoratedBox>(
      find.ancestor(
        of: find.text('Dừng nghe'),
        matching: find.byKey(const Key('listenButtonBackground')),
      ),
    );
    expect((bg.decoration as ShapeDecoration).color, Palette.accent);
    await t.tap(find.text('Dừng nghe'));
    expect(calls2.log, ['stop']);
  });

  testWidgets('idle listen button uses the surface background', (t) async {
    await pump(t, state());
    final bg = t.widget<DecoratedBox>(
      find.ancestor(
        of: find.text('Bắt đầu nghe'),
        matching: find.byKey(const Key('listenButtonBackground')),
      ),
    );
    expect((bg.decoration as ShapeDecoration).color, Palette.surface);
  });

  testWidgets('listen button is disabled until the phase is running', (t) async {
    final calls = await pump(t, state(phase: UiPhase.idle));
    await t.tap(find.text('Bắt đầu nghe'));
    expect(calls.log, isEmpty);
  });

  testWidgets('trash is disabled without history', (t) async {
    final calls = await pump(t, state());
    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pump();
    expect(find.text('Xoá toàn bộ hội thoại?'), findsNothing);
    expect(calls.log, isEmpty);
  });

  testWidgets('trash asks first; Huỷ keeps, Xoá clears', (t) async {
    final calls = await pump(
      t,
      state(theirs: [line('a', 'Hello', 'Xin chào', 0)]),
    );
    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();
    expect(find.text('Xoá toàn bộ hội thoại?'), findsOneWidget);
    expect(calls.log, isEmpty);
    await t.tap(find.text('Huỷ'));
    await t.pumpAndSettle();
    expect(calls.log, isEmpty);
    expect(find.text('Xoá toàn bộ hội thoại?'), findsNothing);

    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();
    await t.tap(find.text('Xoá'));
    await t.pumpAndSettle();
    expect(calls.log, ['clear']);
  });

  testWidgets('settings menu: three items, clear asks first', (t) async {
    final calls = await pump(
      t,
      state(theirs: [line('a', 'Hello', 'Xin chào', 0)]),
    );
    await t.tap(find.byTooltip('Cài đặt'));
    await t.pumpAndSettle();
    expect(find.text('Ngôn ngữ'), findsOneWidget);
    expect(find.text('Từ điển riêng'), findsOneWidget);
    expect(find.text('Xoá hội thoại'), findsOneWidget);
    expect(find.textContaining('relay'), findsNothing);
    await t.tap(find.text('Xoá hội thoại'));
    await t.pumpAndSettle();
    expect(calls.log, isEmpty);
    expect(find.text('Xoá toàn bộ hội thoại?'), findsOneWidget);
    await t.tap(find.text('Xoá'));
    await t.pumpAndSettle();
    expect(calls.log, ['clear']);
  });

  testWidgets('settings menu opens languages and glossary', (t) async {
    final calls = await pump(t, state());
    await t.tap(find.byTooltip('Cài đặt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Ngôn ngữ'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Cài đặt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Từ điển riêng'));
    await t.pumpAndSettle();
    expect(calls.log, ['languages', 'glossary']);
  });

  testWidgets('settings menu clear is disabled without history', (t) async {
    final calls = await pump(t, state());
    await t.tap(find.byTooltip('Cài đặt'));
    await t.pumpAndSettle();
    await t.tap(find.text('Xoá hội thoại'));
    await t.pumpAndSettle();
    expect(find.text('Xoá toàn bộ hội thoại?'), findsNothing);
    expect(calls.log, isEmpty);
  });

  testWidgets('header pill shows the pair and opens the language sheet', (
    t,
  ) async {
    final calls = await pump(t, state());
    expect(find.text('Tiếng Việt'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    await t.tap(find.text('English'));
    expect(calls.log, ['languages']);
  });

  testWidgets('board mic button toggles and is disabled until ready', (
    t,
  ) async {
    final calls = await pump(t, state());
    await t.tap(find.byIcon(Icons.mic_none));
    expect(calls.log, ['mic']);

    final off = await pump(t, state(board: BoardState.scanning));
    await t.pump();
    await t.tap(find.byIcon(Icons.mic_none));
    expect(off.log, isEmpty);

    await pump(t, state(boardMicOn: false));
    await t.pump();
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('status line: waiting / listening and board text', (t) async {
    await pump(t, state());
    expect(find.text('Đang chờ'), findsOneWidget);
    expect(find.text('· Board đã kết nối'), findsOneWidget);
    await pump(t, state(listening: true, boardMicOn: false));
    await t.pump();
    expect(find.text('Đang nghe'), findsOneWidget);
    expect(find.text('· Board đã kết nối · mic tắt'), findsOneWidget);
    for (final (b, s) in [
      (BoardState.off, '· Bluetooth đang tắt'),
      (BoardState.scanning, '· Đang tìm board…'),
      (BoardState.connecting, '· Đang kết nối…'),
    ]) {
      await pump(t, state(board: b));
      await t.pump();
      expect(find.text(s), findsOneWidget);
    }
  });

  testWidgets('lines are ordered by time across both sides', (t) async {
    await pump(
      t,
      state(
        theirs: [line('a', 'late', 'muộn', 30), line('b', 'early', 'sớm', 10)],
        mine: [line('c', 'giữa', 'middle', 20)],
      ),
    );
    final ys = [
      for (final s in ['sớm', 'middle', 'muộn']) t.getTopLeft(find.text(s)).dy,
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: '$ys');
    expect(find.text('Họ nói'), findsNWidgets(2));
    expect(find.text('Bạn nói'), findsOneWidget);
  });

  testWidgets('my lines with an empty source are hidden', (t) async {
    await pump(t, state(mine: [line('c', '', 'hidden', 5)]));
    expect(find.text('hidden'), findsNothing);
    expect(find.text('Bạn nói'), findsNothing);
  });

  testWidgets('partials are italic and faint', (t) async {
    await pump(
      t,
      state(listening: true, theirPartial: 'hel', myPartial: 'xin'),
    );
    for (final p in ['hel', 'xin']) {
      final style = t.widget<Text>(find.text(p)).style!;
      expect(style.fontStyle, FontStyle.italic);
      expect(style.color, Palette.faint);
    }
  });

  testWidgets('unclear targets are faint, clear ones are text coloured', (
    t,
  ) async {
    await pump(
      t,
      state(
        theirs: [
          line('a', 'mumble', 'lầm bầm', 1, unclear: true),
          line('b', 'hello', 'xin chào', 2),
        ],
      ),
    );
    expect(textColor(t, 'lầm bầm'), Palette.faint);
    expect(textColor(t, 'xin chào'), Palette.text);
    expect(textColor(t, 'mumble'), Palette.muted);
  });

  testWidgets('empty hints match the Swift app', (t) async {
    await pump(t, state());
    expect(find.text('Chạm "Bắt đầu nghe" trước khi nói'), findsOneWidget);
    expect(
      find.text(
        'Người đối diện nói vào board, bạn nghe tiếng Việt qua AirPods. '
        'Bạn nói tiếng Việt, họ đọc phụ đề trên board.',
      ),
      findsOneWidget,
    );
    await pump(t, state(listening: true));
    await t.pump();
    expect(find.text('Cứ nói đi'), findsOneWidget);
    await pump(t, state(theirPartial: 'x'));
    await t.pump();
    expect(find.text('Chạm "Bắt đầu nghe" trước khi nói'), findsNothing);
  });

  testWidgets('autoscroll goes to the end, also when a line is added', (
    t,
  ) async {
    final many = [
      for (var i = 0; i < 30; i++) line('l$i', 'source $i', 'target $i', i),
    ];
    useIphoneSize(t);
    final calls = Calls();
    Widget app(List<UiLine> l) => harness(
      ConversationScreen(state: state(theirs: l), actions: calls.actions),
    );
    await t.pumpWidget(app(many));
    await t.pumpAndSettle();
    final sc = t.state<ScrollableState>(find.byType(Scrollable).first);
    expect(sc.position.maxScrollExtent, greaterThan(0));
    expect(sc.position.pixels, sc.position.maxScrollExtent);

    await t.pumpWidget(app([...many, line('new', 'brand new', 'mới tinh', 99)]));
    await t.pumpAndSettle();
    expect(sc.position.pixels, sc.position.maxScrollExtent);
    expect(find.text('mới tinh'), findsOneWidget);
  });

  testWidgets('"online" chip follows onlineRecognizer', (t) async {
    await pump(t, state());
    expect(find.text('online'), findsNothing);
    await pump(t, state(online: true));
    await t.pump();
    expect(find.text('online'), findsOneWidget);
  });

  testWidgets('"mic điện thoại" chip while listening on the phone mic', (
    t,
  ) async {
    await pump(t, state(listening: true));
    expect(find.text('mic điện thoại'), findsNothing);
    await pump(t, state(listening: true, route: AudioRoute.phoneMic));
    await t.pump();
    expect(find.text('mic điện thoại'), findsOneWidget);
    await pump(t, state(listening: false, route: AudioRoute.phoneMic));
    await t.pump();
    expect(find.text('mic điện thoại'), findsNothing);
  });

  testWidgets('preparing shows its message, no control bar', (t) async {
    await pump(
      t,
      state(phase: UiPhase.preparing, message: 'Đang tải mô hình…'),
    );
    expect(find.text('Đang tải mô hình…'), findsOneWidget);
    expect(find.text('Bắt đầu nghe'), findsNothing);
  });

  testWidgets('failed shows reason and Thử lại', (t) async {
    final calls = await pump(
      t,
      state(phase: UiPhase.failed, message: 'Không mở được mic'),
    );
    expect(find.text('Không khởi động được'), findsOneWidget);
    expect(find.text('Không mở được mic'), findsOneWidget);
    await t.tap(find.text('Thử lại'));
    expect(calls.log, ['retry']);
  });

  testWidgets('needsDownload renders the readiness view', (t) async {
    final calls = await pump(
      t,
      state(phase: UiPhase.needsDownload, session: const Checking('en')),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(calls.log, isEmpty);
  });

  testWidgets('NeedsDownload names languages from languageNames', (t) async {
    final calls = await pump(
      t,
      state(
        phase: UiPhase.needsDownload,
        session: NeedsDownload('en', [
          MissingMsg(
            kind: MissingKind.translation,
            language: 'en',
            from: 'en',
            to: 'vi',
          ),
        ]),
      ),
    );
    expect(find.text('Bản dịch English → Tiếng Việt'), findsOneWidget);
    await t.tap(find.text('Tải về'));
    expect(calls.log, ['download']);
  });

  testWidgets('Choosing lists offeredPacks and a tap calls pickLanguage', (
    t,
  ) async {
    final calls = await pump(
      t,
      state(
        phase: UiPhase.needsDownload,
        session: const Choosing(),
        offered: [
          LanguagePack(
            code: 'ja',
            appleLocale: 'x',
            androidLocale: 'x',
            whisperCode: 'ja',
            label: '日本語',
            labelLatin: 'Japanese',
            script: Script.cjk,
          ),
        ],
      ),
    );
    expect(find.text('日本語'), findsOneWidget);
    await t.tap(find.text('日本語'));
    expect(calls.log, ['pick ja']);
  });

  testWidgets('Downloading shows the determinate progress', (t) async {
    await pump(
      t,
      state(
        phase: UiPhase.needsDownload,
        session: const Downloading('en'),
        progress: 0.5,
      ),
    );
    expect(find.text('Đang tải… 50%'), findsOneWidget);
    expect(
      t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
      0.5,
    );
  });

  group('goldens (393x852)', () {
    testWidgets('empty', (t) async {
      await pump(t, state());
      await expectLater(
        find.byType(ConversationScreen),
        matchesGoldenFile('goldens/empty.png'),
      );
    });

    testWidgets('conversation, listening, online, phone mic', (t) async {
      await pump(
        t,
        state(
          listening: true,
          online: true,
          route: AudioRoute.phoneMic,
          theirs: [
            line('a', 'Where is the train station?', 'Ga tàu ở đâu vậy?', 0),
            line('b', 'mumble mumble', 'lầm bầm gì đó', 20, unclear: true),
          ],
          mine: [
            line(
              'c',
              'Đi thẳng rồi rẽ phải nhé',
              'Go straight, then turn right.',
              10,
            ),
          ],
          theirPartial: 'and how far is it',
          myPartial: 'khoảng năm phút đi bộ',
        ),
      );
      await expectLater(
        find.byType(ConversationScreen),
        matchesGoldenFile('goldens/conversation.png'),
      );
    });

    testWidgets('failed', (t) async {
      await pump(
        t,
        state(
          phase: UiPhase.failed,
          message: 'Không mở được mic',
          board: BoardState.off,
        ),
      );
      await expectLater(
        find.byType(ConversationScreen),
        matchesGoldenFile('goldens/failed.png'),
      );
    });
  });
}
