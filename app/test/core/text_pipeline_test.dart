import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/core/text_pipeline.dart';

LanguagePack bare(String code, {List<Rule> before = const [], List<Term> terms = const []}) =>
    LanguagePack(
      code: code,
      appleLocale: '$code-X',
      androidLocale: '$code-X',
      whisperCode: code,
      label: code.toUpperCase(),
      labelLatin: code.toUpperCase(),
      script: Script.latin,
      beforeTranslation: before,
      terms: terms,
    );

final vi = LanguagePack.parse(File('assets/languages/vi.json').readAsStringSync());
final en = bare('en');
final ja = bare('ja');
final fr = bare('fr');

/// A fake translator: tags the text and keeps placeholders as they are.
Future<String> fakeTranslate(String s) async => '<${s.toUpperCase()}>';

void main() {
  group('prepare / finish, mine (Vietnamese to the other language)', () {
    test('applies loanword and translator rules, then restores terms', () {
      final p = TextPipeline(home: vi, other: en, glossary: [
        const Term(id: 'g1', text: 'Bến Thành', fixed: {'en': 'Ben Thanh'}),
      ]);
      final prep = p.prepare('Em ơi, đi chợ Bến Thành bằng giữa lo', Direction.mine);
      // vocative dropped, term masked ("giữa lo" after "bằng" is the Zalo rule)
      expect(prep.text, 'Đi chợ Zorvik1 bằng Zalo');
      expect(p.finish('Go to Zorvik1 by Zalo', prep), 'Go to Ben Thanh by Zalo');
    });

    test('vocatives are dropped for ja and fr targets too', () {
      for (final other in [ja, fr]) {
        final p = TextPipeline(home: vi, other: other);
        expect(p.prepare('Em ơi, tính tiền!', Direction.mine).text, 'Cho tôi thanh toán!');
        expect(p.prepare('Chị ơi, cho em hai ly trà', Direction.mine).text, 'Cho em hai ly trà');
      }
    });

    test('vocatives only are kept rather than translating nothing', () {
      final p = TextPipeline(home: vi, other: ja);
      expect(p.prepare('Em ơi', Direction.mine).text, 'Em ơi');
    });

    test('fixed translations are chosen by the target language', () {
      const phoTerm = Term(id: 'pho', text: 'Phở', fixed: {'en': 'Pho soup', 'ja': 'フォー'});
      for (final (other, expected) in [(en, 'Pho soup'), (ja, 'フォー'), (fr, 'Phở')]) {
        final p = TextPipeline(home: vi, other: other, glossary: [phoTerm]);
        final prep = p.prepare('Một tô Phở', Direction.mine);
        expect(prep.text, 'Một tô Zorvik1');
        expect(p.finish('X Zorvik1', prep), 'X $expected');
      }
    });

    test('built-in pack terms are protected and the glossary wins', () {
      final pack = bare('en', terms: const [Term(id: 'b', text: 'Grab', origin: TermOrigin.builtIn)]);
      final p = TextPipeline(home: vi, other: pack, glossary: [
        const Term(id: 'u', text: 'Grab', fixed: {'en': 'Grab Car'}),
      ]);
      final prep = p.prepare('Tôi gọi Grab', Direction.mine);
      expect(p.finish('I call Zorvik1', prep), 'I call Grab Car');
    });
  });

  group('prepare / finish, theirs (the other language to Vietnamese)', () {
    test('the other pack has no vocative rules: text is untouched', () {
      final p = TextPipeline(home: vi, other: en);
      final prep = p.prepare('Hey, how much?', Direction.theirs);
      expect(prep.text, 'Hey, how much?');
      expect(p.finish('Này, bao nhiêu?', prep), 'Này, bao nhiêu?');
    });

    test('glossary terms found in the other language are protected', () {
      final p = TextPipeline(home: vi, other: en, glossary: [
        const Term(id: 'g', text: 'Ben Thanh Market', variants: ['Ben Thanh'], fixed: {'vi': 'chợ Bến Thành'}),
      ]);
      final prep = p.prepare('Take me to Ben Thanh Market please', Direction.theirs);
      expect(prep.text, 'Take me to Zorvik1 please');
      expect(p.finish('Đưa tôi đến Zorvik1 nhé', prep), 'Đưa tôi đến chợ Bến Thành nhé');
    });

    test('the other pack\'s own before-translation rules apply to its speech', () {
      final other = bare('xx', before: const [Rule(id: 'r', pattern: 'gonna', template: 'going to')]);
      final p = TextPipeline(home: vi, other: other);
      expect(p.prepare("I'm gonna go", Direction.theirs).text, "I'm going to go");
    });
  });

  group('placeholder shape comes from the config', () {
    test('per target language, with a default', () {
      final p = TextPipeline(
        home: vi,
        other: ja,
        glossary: const [Term(id: 'a', text: 'Zalo')],
        placeholders: const {'ja': 'QX{n}Z'},
      );
      expect(p.prepare('Tôi dùng Zalo', Direction.mine).text, 'Tôi dùng QX1Z');
      final q = TextPipeline(home: vi, other: fr, glossary: const [Term(id: 'a', text: 'Zalo')], placeholders: const {'ja': 'QX{n}Z'});
      expect(q.prepare('Tôi dùng Zalo', Direction.mine).text, 'Tôi dùng Zorvik1');
    });
  });

  group('translate', () {
    test('runs prepare, the injected translator and finish', () async {
      final p = TextPipeline(home: vi, other: en, glossary: const [
        Term(id: 'g', text: 'Hà Nội', fixed: {'en': 'Hanoi'}),
      ]);
      final out = await p.translate('Em ơi, đến Hà Nội', Direction.mine, fakeTranslate);
      expect(out, '<ĐẾN Hanoi>');
      expect(p.lostPlaceholders, 0);
    });

    test('empty text is not translated', () async {
      var calls = 0;
      final p = TextPipeline(home: vi, other: en);
      final out = await p.translate('  ', Direction.mine, (s) async {
        calls++;
        return s;
      });
      expect(out, '');
      expect(calls, 0);
    });

    test('a lost placeholder falls back to the unmasked text and repairs fixed terms', () async {
      final p = TextPipeline(home: vi, other: en, glossary: const [
        Term(id: 'g', text: 'Chợ Bến Thành', fixed: {'en': 'Ben Thanh Market'}),
      ]);
      final seen = <String>[];
      final out = await p.translate('Tôi ở Chợ Bến Thành', Direction.mine, (s) async {
        seen.add(s);
        // masked request: the translator eats the placeholder
        return s.contains('Zorvik') ? 'I am here' : 'I am at Chợ Bến Thành';
      });
      expect(seen, ['Tôi ở Zorvik1', 'Tôi ở Chợ Bến Thành']);
      expect(out, 'I am at Ben Thanh Market');
      expect(p.lostPlaceholders, 1);
    });

    test('a translator error propagates', () {
      final p = TextPipeline(home: vi, other: en);
      expect(
        p.translate('xin chào', Direction.mine, (s) async => throw StateError('boom')),
        throwsStateError,
      );
    });
  });
}
