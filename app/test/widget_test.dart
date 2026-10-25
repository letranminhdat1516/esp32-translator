import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/main.dart';

import 'ui/ui_test_helpers.dart';

void main() {
  setUpAll(loadTestFont);
  testWidgets('demo shell shows the conversation and toggles listening', (
    tester,
  ) async {
    useIphoneSize(tester);
    final packs = (await tester.runAsync(loadDemoPacks))!;
    expect(packs, isNotEmpty);
    await tester.pumpWidget(DemoApp(packs: packs, fontFamily: testFont));
    expect(find.text('Ga tàu ở đâu vậy?'), findsOneWidget);
    expect(find.text(packs.first.label), findsOneWidget);
    expect(find.text('Bắt đầu nghe'), findsOneWidget);
    await tester.tap(find.text('Bắt đầu nghe'));
    await tester.pump();
    expect(find.text('Dừng nghe'), findsOneWidget);
    await tester.tap(find.text('Dừng nghe'));
    await tester.pump();
    expect(find.text('Bắt đầu nghe'), findsOneWidget);
  });
}
