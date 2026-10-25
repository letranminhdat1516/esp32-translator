import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/subtitle_translator.dart';

/// A fake translator: upper-cases the text after a delay and records every
/// request.
class FakeTranslator {
  FakeTranslator({this.delay = const Duration(milliseconds: 5)});

  final Duration delay;
  final List<String> requests = [];
  final Set<String> failing = {};

  void fail(String text) => failing.add(text);

  Future<String> translate(String text) async {
    requests.add(text);
    await Future<void>.delayed(delay);
    if (failing.contains(text)) throw Exception('cancelled');
    return text.toUpperCase();
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  late FakeTranslator fake;
  late Map<int, String> byTurn;

  SubtitleTranslator make([FakeTranslator? f]) {
    fake = f ?? FakeTranslator();
    byTurn = {};
    return SubtitleTranslator(
      translate: fake.translate,
      onResult: (turn, text) => byTurn[turn] = text,
    );
  }

  test('finals are translated once and joined', () async {
    final st = make();
    st.setPartial('xin', turn: 1);
    st.setPartial('xin chào', turn: 1);
    st.addFinal('xin chào', turn: 1);
    st.setPartial('', turn: 1);
    st.setPartial('anh', turn: 1);
    st.addFinal('anh khỏe không', turn: 1);
    st.setPartial('', turn: 1);
    await settle();
    expect(byTurn[1], 'XIN CHÀO ANH KHỎE KHÔNG');
    // Each final once; partials only while current (latest wins)
    expect(fake.requests.where((r) => r == 'xin chào').length, lessThanOrEqualTo(2));
    expect(fake.requests.where((r) => r == 'anh khỏe không').length, 1);
  });

  test('late final of an earlier turn lands in that turn', () async {
    // The old latest-wins translator wrote every result into the last line: a
    // phrase finalized just before a new turn started lost its translation in
    // its own line.
    final st = make(FakeTranslator(delay: const Duration(milliseconds: 50)));
    st.addFinal('một', turn: 1);
    st.addFinal('hai', turn: 1);
    st.setPartial('ba', turn: 2);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(byTurn[1], 'MỘT HAI');
    expect(byTurn[2], 'BA');
  });

  test('a failed translation keeps the volatile English', () async {
    final st = make();
    fake.fail('bốn năm');
    st.setPartial('bốn', turn: 1);
    await settle();
    st.addFinal('bốn năm', turn: 1);
    await settle();
    expect(byTurn[1], 'BỐN');
  });

  test('request length does not grow with the turn', () async {
    // Requests stay one phrase long however long the turn gets.
    final st = make(FakeTranslator(delay: const Duration(milliseconds: 1)));
    for (var i = 0; i < 30; i++) {
      st.setPartial('câu số $i', turn: 1);
      st.addFinal('câu số $i xong', turn: 1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await settle();
    final longest = fake.requests.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
    expect(longest, lessThanOrEqualTo('câu số 29 xong'.length));
    expect(byTurn[1]!.split(' ').where((w) => w.isNotEmpty).length, 30 * 4);
  });

  test('empty phrases are not translated', () async {
    final st = make();
    st.addFinal('một', turn: 1);
    st.addFinal('', turn: 1);
    st.addFinal('hai', turn: 1);
    await settle();
    expect(fake.requests.contains(''), isFalse);
    expect(byTurn[1], 'MỘT HAI');
  });

  test('reset drops pending work', () async {
    final st = make(FakeTranslator(delay: const Duration(milliseconds: 50)));
    st.addFinal('một', turn: 1);
    st.addFinal('hai', turn: 1);
    st.reset();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(byTurn[1] == null || byTurn[1] == '', isTrue);
  });
}
