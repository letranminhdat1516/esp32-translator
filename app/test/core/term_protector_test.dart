import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/core/term_protector.dart';

Term term(String text, {List<String> variants = const [], Map<String, String> fixed = const {}}) =>
    Term(id: text, text: text, variants: variants, fixed: fixed);

void main() {
  const protector = TermProtector();

  group('mask', () {
    test('replaces a term with a numbered placeholder', () {
      final m = protector.mask('Tôi ở Bến Thành', [term('Bến Thành')], 'en');
      expect(m.text, 'Tôi ở Zorvik1');
      expect(m.isEmpty, isFalse);
    });

    test('no terms or no match leaves the text and restore is a no-op', () {
      final m = protector.mask('Xin chào', [term('Hà Nội')], 'en');
      expect(m.text, 'Xin chào');
      expect(m.isEmpty, isTrue);
      expect(protector.restore('Hello', m), 'Hello');
      expect(protector.mask('Xin chào', const [], 'en').text, 'Xin chào');
    });

    test('Review Focus 3: regex characters, overlap, longest first', () {
      final terms = [
        term('C++'),
        term('Q.1'),
        term('Bến Thành'),
        term('Chợ Bến Thành', fixed: {'en': 'Ben Thanh Market'}),
      ];
      const text = 'Tôi viết C++ ở Q.1 gần Bến Thành rồi tới Chợ Bến Thành';
      final m = protector.mask(text, terms, 'en');
      // "Chợ Bến Thành" is one token; "Bến Thành" inside it is not masked again
      expect(m.text, 'Tôi viết Zorvik1 ở Zorvik2 gần Zorvik3 rồi tới Zorvik4');
      expect(m.text.contains('Zorvik5'), isFalse);
      final back = protector.restore(
        'I write Zorvik1 in Zorvik2 near Zorvik3 then to Zorvik4',
        m,
      );
      expect(
        back,
        'I write C++ in Q.1 near Bến Thành then to Ben Thanh Market',
      );
    });

    test('regex metacharacters in a term are matched literally', () {
      final m = protector.mask(r'gọi (A|B) [x] ^$ .* nhé', [term('(A|B)'), term('[x]'), term(r'^$'), term('.*')], 'en');
      expect(m.text, 'gọi Zorvik1 Zorvik2 Zorvik3 Zorvik4 nhé');
      // "." alone must not match any character
      final dot = protector.mask('abc', [term('.')], 'en');
      expect(dot.text, 'abc');
    });

    test('longest term wins even when listed after the shorter one', () {
      final terms = [term('Bến Thành'), term('Chợ Bến Thành')];
      final m = protector.mask('Chợ Bến Thành', terms, 'en');
      expect(m.text, 'Zorvik1');
    });

    test('Latin matching is case-insensitive and keeps the spoken form', () {
      final m = protector.mask('đi chợ bến thành nhé', [term('Bến Thành')], 'en');
      expect(m.text, 'đi chợ Zorvik1 nhé');
      expect(protector.restore('go to Zorvik1', m), 'go to bến thành');
      final up = protector.mask('BẾN THÀNH', [term('Bến Thành')], 'en');
      expect(up.text, 'Zorvik1');
    });

    test('other scripts match exactly', () {
      final m = protector.mask('Москва и москва', [term('Москва')], 'en');
      expect(m.text, 'Zorvik1 и москва');
    });

    test('whole words only for spaced scripts', () {
      final terms = [term('An'), term('Q.1')];
      final m = protector.mask('Anh An ở Q.10 và Q.1', terms, 'en');
      expect(m.text, 'Anh Zorvik1 ở Q.10 và Zorvik2');
    });

    test('no word boundary inside scripts written without spaces', () {
      final m = protector.mask('東京に行く', [term('東京')], 'en');
      expect(m.text, 'Zorvik1に行く');
    });

    test('variants are matched and share the term\'s fixed translation', () {
      final t = term('Hà Nội', variants: ['Hanoi'], fixed: {'en': 'Hanoi'});
      final m = protector.mask('Hà Nội và hanoi', [t], 'en');
      expect(m.text, 'Zorvik1 và Zorvik1');
      expect(protector.restore('Zorvik1 and Zorvik1', m), 'Hanoi and Hanoi');
    });

    test('fixed translation is chosen per target; absent means verbatim', () {
      final t = term('Phở', fixed: {'en': 'Pho noodle soup', 'ja': 'フォー'});
      final en = protector.mask('Một tô Phở', [t], 'en');
      expect(protector.restore('A bowl of Zorvik1', en), 'A bowl of Pho noodle soup');
      final ja = protector.mask('Một tô Phở', [t], 'ja');
      expect(protector.restore('Zorvik1を一杯', ja), 'フォーを一杯');
      final fr = protector.mask('Một tô Phở', [t], 'fr');
      expect(protector.restore('Un bol de Zorvik1', fr), 'Un bol de Phở');
    });

    test('different spoken forms of one term without fixed get own tokens', () {
      final t = term('Grab');
      final m = protector.mask('Grab và grab', [t], 'en');
      expect(m.text, 'Zorvik1 và Zorvik2');
      expect(protector.restore('Zorvik1 and Zorvik2', m), 'Grab and grab');
    });

    test('repeating the same term reuses its token', () {
      final m = protector.mask('Zalo hoặc Zalo', [term('Zalo')], 'en');
      expect(m.text, 'Zorvik1 hoặc Zorvik1');
    });

    test('numbers skip tokens already present in the text', () {
      final m = protector.mask('Zorvik1 là Zalo', [term('Zalo')], 'en');
      expect(m.text, 'Zorvik1 là Zorvik2');
      expect(protector.restore('Zorvik1 is Zorvik2', m), 'Zorvik1 is Zalo');
    });

    test('a custom placeholder shape', () {
      final m = protector.mask('ở Hà Nội', [term('Hà Nội')], 'en', placeholder: '[[{n}]]');
      expect(m.text, 'ở [[1]]');
      expect(protector.restore('in [[1]]', m), 'in Hà Nội');
    });

    test('a placeholder without {n} is rejected', () {
      expect(
        () => protector.mask('x', [term('x')], 'en', placeholder: 'Zorvik'),
        throwsArgumentError,
      );
    });

    test('empty terms are ignored', () {
      final m = protector.mask('abc', [term('')], 'en');
      expect(m.text, 'abc');
    });
  });

  group('restore', () {
    test('a lost placeholder returns null', () {
      final m = protector.mask('Q.1 và Bến Thành', [term('Q.1'), term('Bến Thành')], 'en');
      expect(protector.restore('District one and Zorvik2', m), isNull);
      expect(protector.restore('Zorvik1 and Zorvik2', m), 'Q.1 and Bến Thành');
    });

    test('tokens come back in any case and order', () {
      final m = protector.mask('A và B', [term('A'), term('B')], 'en');
      expect(protector.restore('zorvik2 then ZORVIK1', m), 'B then A');
    });

    test('Zorvik1 is not confused with Zorvik10', () {
      final terms = [for (var i = 1; i <= 10; i++) term('T$i')];
      final text = [for (var i = 1; i <= 10; i++) 'T$i'].join(' ');
      final m = protector.mask(text, terms, 'en');
      expect(m.text, [for (var i = 1; i <= 10; i++) 'Zorvik$i'].join(' '));
      expect(protector.restore(m.text, m), text);
    });

    test('restored text is not scanned again', () {
      final t = term('Zorvik2', fixed: {'en': 'Zorvik1'});
      final m = protector.mask('a Zorvik2 b', [t], 'en');
      final out = protector.restore('x ${m.text.split(' ')[1]} y', m);
      expect(out, 'x Zorvik1 y');
    });


    test('one of two copies dropped returns null', () {
      final m = protector.mask('Zalo hoặc Zalo', [term('Zalo')], 'en');
      expect(protector.restore('Zorvik1 or Zorvik1', m), 'Zalo or Zalo');
      expect(protector.restore('Zorvik1 or nothing', m), isNull);
    });

    test('a duplicated placeholder returns null', () {
      final m = protector.mask('Tôi dùng Zalo', [term('Zalo')], 'en');
      expect(protector.restore('Zorvik1 Zorvik1', m), isNull);
    });

    test('a placeholder the translator invented returns null', () {
      final m = protector.mask('A và B', [term('A'), term('B')], 'en');
      expect(protector.restore('Zorvik1 Zorvik2 Zorvik9', m), isNull);
    });

    test('a number that was in the source text may stay', () {
      final m = protector.mask('Zorvik1 là Zalo', [term('Zalo')], 'en');
      expect(protector.restore('Zorvik1 is Zorvik2', m), 'Zorvik1 is Zalo');
    });
  });
}
