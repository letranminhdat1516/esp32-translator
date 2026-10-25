import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/ui/glossary_screen.dart';

import 'ui_test_helpers.dart';

/// Owns the list like the controller will: applies the callbacks, then
/// rebuilds the screen with the new terms.
class Host extends StatefulWidget {
  const Host({super.key, this.initial = const [], this.reject});
  final List<Term> initial;

  /// Throws this message instead of applying a change.
  final String? reject;

  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> {
  late List<Term> terms = [...widget.initial];
  final log = <String>[];
  var _n = 0;

  void _check() {
    if (widget.reject != null) throw GlossaryValidationError(widget.reject!);
  }

  @override
  Widget build(BuildContext context) => GlossaryScreen(
    terms: terms,
    onAdd: (text) {
      log.add('add $text');
      _check();
      setState(() => terms = [...terms, Term(id: 'n${_n++}', text: text)]);
    },
    onUpdate: (id, text) {
      log.add('update $id $text');
      _check();
      setState(
        () => terms = [
          for (final x in terms) x.id == id ? Term(id: id, text: text) : x,
        ],
      );
    },
    onDelete: (id) {
      log.add('delete $id');
      setState(() => terms = [...terms]..removeWhere((x) => x.id == id));
    },
  );
}

const alpha = Term(id: 'a', text: 'Zorvik');
const beta = Term(id: 'b', text: 'Cicca', variants: ['Chika']);
const builtIn = Term(id: 'c', text: 'iPhone', origin: TermOrigin.builtIn);

Future<HostState> show(WidgetTester t, {List<Term> terms = const [], String? reject}) async {
  useIphoneSize(t);
  await t.pumpWidget(harness(Host(key: UniqueKey(), initial: terms, reject: reject)));
  return t.state<HostState>(find.byType(Host));
}

void main() {
  setUpAll(loadTestFont);

  testWidgets('shows the title and the terms, empty hint without terms', (t) async {
    await show(t);
    expect(find.text('Từ điển riêng'), findsOneWidget);
    expect(find.text('Chưa có từ nào'), findsOneWidget);
    final h = await show(t, terms: [alpha, beta]);
    await t.pump();
    expect(h.terms.length, 2);
    expect(find.text('Zorvik'), findsOneWidget);
    expect(find.text('Cicca'), findsOneWidget);
    expect(find.text('Chika'), findsOneWidget);
    expect(find.text('Chưa có từ nào'), findsNothing);
  });

  testWidgets('add: the term lands in the list and the field clears', (t) async {
    final h = await show(t);
    await t.enterText(find.byKey(const Key('glossaryField')), 'Zorvik');
    await t.tap(find.text('Thêm'));
    await t.pump();
    expect(h.log, ['add Zorvik']);
    expect(find.text('Zorvik'), findsOneWidget);
    expect(
      t.widget<TextField>(find.byKey(const Key('glossaryField'))).controller!.text,
      '',
    );
  });

  for (final message in [
    'Từ không được để trống',
    'Tối đa 64 ký tự',
    'Tối đa 500 từ',
    'Có ký tự không hợp lệ',
  ]) {
    testWidgets('add rejected: "$message" shown under the field', (t) async {
      final h = await show(t, reject: message);
      await t.enterText(find.byKey(const Key('glossaryField')), 'x');
      await t.tap(find.text('Thêm'));
      await t.pump();
      expect(find.text(message), findsOneWidget);
      expect(h.terms, isEmpty);
      // The text stays so the user can fix it, and typing clears the message.
      expect(
        t.widget<TextField>(find.byKey(const Key('glossaryField'))).controller!.text,
        'x',
      );
      await t.enterText(find.byKey(const Key('glossaryField')), 'xy');
      await t.pump();
      expect(find.text(message), findsNothing);
    });
  }

  testWidgets('delete removes the term', (t) async {
    final h = await show(t, terms: [alpha, beta]);
    await t.tap(find.byTooltip('Xoá Zorvik'));
    await t.pump();
    expect(h.log, ['delete a']);
    expect(find.text('Zorvik'), findsNothing);
    expect(find.text('Cicca'), findsOneWidget);
  });

  testWidgets('edit: Lưu updates, Huỷ leaves it', (t) async {
    final h = await show(t, terms: [alpha]);
    await t.tap(find.byTooltip('Sửa Zorvik'));
    await t.pump();
    await t.enterText(find.byKey(const Key('glossaryEditField')), 'Zorvik2');
    await t.tap(find.text('Lưu'));
    await t.pump();
    expect(h.log, ['update a Zorvik2']);
    expect(find.text('Zorvik2'), findsOneWidget);
    expect(find.byKey(const Key('glossaryEditField')), findsNothing);

    await t.tap(find.byTooltip('Sửa Zorvik2'));
    await t.pump();
    await t.tap(find.text('Huỷ'));
    await t.pump();
    expect(h.log.length, 1);
    expect(find.text('Zorvik2'), findsOneWidget);
  });

  testWidgets('edit rejected: message under the edit field, stays open', (t) async {
    await show(t, terms: [alpha], reject: 'Tối đa 64 ký tự');
    await t.tap(find.byTooltip('Sửa Zorvik'));
    await t.pump();
    await t.enterText(find.byKey(const Key('glossaryEditField')), 'y');
    await t.tap(find.text('Lưu'));
    await t.pump();
    expect(find.text('Tối đa 64 ký tự'), findsOneWidget);
    expect(find.byKey(const Key('glossaryEditField')), findsOneWidget);
  });

  testWidgets('built-in terms cannot be edited or deleted', (t) async {
    await show(t, terms: [builtIn]);
    expect(find.text('iPhone'), findsOneWidget);
    expect(find.byTooltip('Sửa iPhone'), findsNothing);
    expect(find.byTooltip('Xoá iPhone'), findsNothing);
  });

  testWidgets('golden: glossary', (t) async {
    await show(t, terms: [alpha, beta, builtIn]);
    await expectLater(
      find.byType(GlossaryScreen),
      matchesGoldenFile('goldens/glossary.png'),
    );
  });
}
