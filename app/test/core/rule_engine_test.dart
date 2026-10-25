import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/core/rule_engine.dart';

LanguagePack loadVi() =>
    LanguagePack.parse(File('assets/languages/vi.json').readAsStringSync());

void main() {
  final pack = loadVi();
  final engine = RuleEngine.forPack(pack);

  group('loanwords', () {
    // Mishearings observed in the measurement spike
    const cases = [
      ('Tôi đang đợi xe Grant out trước cửa khách sạn', 'Tôi đang đợi xe Grab trước cửa khách sạn'),
      ('Tôi đang đợi xe Gran out trước cửa khách sạn', 'Tôi đang đợi xe Grab trước cửa khách sạn'),
      ('Tôi đang đợi xe gram trước cửa khách sạn', 'Tôi đang đợi xe Grab trước cửa khách sạn'),
      ('Bạn có biết mật khẩu hoa phay ở đây không', 'Bạn có biết mật khẩu Wi-Fi ở đây không'),
      ('Bạn có biết mật khẩu khoai tây ở đây không', 'Bạn có biết mật khẩu Wi-Fi ở đây không'),
      ('Bạn có biết mật khẩu phai ở đây không', 'Bạn có biết mật khẩu Wi-Fi ở đây không'),
      ('Ở đây có wifi không em', 'Ở đây có Wi-Fi không em'),
      ('Mình nhắn tin qua giữa lo cho tiện nhé', 'Mình nhắn tin qua Zalo cho tiện nhé'),
      ('Mình nhắn tin qua Zalo lo cho tiện nhé', 'Mình nhắn tin qua Zalo cho tiện nhé'),
      ('1 đối tác ở C nga co nên tháng sau', '1 đối tác ở Singapore nên tháng sau'),
      ('1 đối tác ngở Phi Nga to nên tháng sau', '1 đối tác ở Singapore nên tháng sau'),
      ('1 đối tác ở China com nên tháng sau', '1 đối tác ở Singapore nên tháng sau'),
      ('gửi qua phây búc nhé', 'gửi qua Facebook nhé'),
      ('gửi i meo cho chị', 'gửi email cho chị'),
      ('ô kê mai gặp nhé', 'OK mai gặp nhé'),
    ];
    for (final (heard, meant) in cases) {
      test('fixes "$heard"', () {
        expect(engine.fixRecognition(heard), meant);
      });
    }
  });

  group('loanwords leave ordinary words', () {
    const texts = [
      'Tôi lo lắng giữa lo âu và hy vọng',
      'Tôi mua khoai tây ở chợ',
      'Một gram vàng giá bao nhiêu',
      'Xe ra cổng rồi',
      'Bông hoa pha lê đẹp quá',
      'Ngỡ ngàng quá',
    ];
    for (final text in texts) {
      test('keeps "$text"', () {
        expect(engine.fixRecognition(text), text);
      });
    }
  });

  group('forTranslation', () {
    const cases = [
      // Wrong VI->EN cases from the spike
      ('Em ơi, tính tiền!', 'Cho tôi thanh toán!'),
      ('Em ơi tính tiền', 'Cho tôi thanh toán'),
      (
        'Cái áo này giá ba trăm nghìn, em lấy anh hai trăm rưỡi thôi.',
        'Cái áo này giá ba trăm nghìn, em tính anh hai trăm năm mươi thôi.',
      ),
      ('em lấy anh 250.000 thôi', 'em tính anh 250.000 thôi'),
      ('Thôi kệ đi, đừng để bụng.', 'Thôi kệ đi, đừng giận.'),
      ('Ăn quả nhớ kẻ trồng cây.', 'Hãy biết ơn những người đã giúp đỡ mình.'),
      // Awkward cases
      ('Anh ơi, cho em hỏi đường ra bến xe với ạ.', 'Cho em hỏi đường ra bến xe với ạ.'),
      ('Mắc quá, bớt chút đi chị.', 'Đắt quá, giảm giá chút đi chị.'),
      ('Đi đâu mà vội mà vàng.', 'Sao phải vội vàng thế.'),
      // Vocative at the end, and loanwords before translation
      ('Cho em hai ly trà đá nhé chị ơi', 'Cho em hai ly trà đá nhé'),
      ('mật khẩu hoa phay là gì vậy anh ơi', 'mật khẩu Wi-Fi là gì vậy'),
      ('Chị ơi, tính tiền giùm em', 'Cho tôi thanh toán'),
      ('Mắc quá, giá này bớt chút đi', 'Đắt quá, giá này giảm giá chút đi'),
      // Vocatives only: keep them (otherwise nothing is left to translate)
      ('Ông ơi, ông bà ơi', 'Ông ơi, ông bà ơi'),
      ('Em ơi', 'Em ơi'),
      ('Em ơi!', 'Em ơi!'),
      ('Bà ơi bà ở đâu?', 'Bà ở đâu?'),
    ];
    for (final (spoken, translated) in cases) {
      test('rewrites "$spoken"', () {
        expect(engine.forTranslation(spoken), translated);
      });
    }
  });

  group('forTranslation leaves other sentences', () {
    const texts = [
      'Em lấy anh hai cái nhé.',
      'Anh lấy em nhé, em đồng ý không?',
      'Tôi bị mắc kẹt trong thang máy.',
      'Bớt chút đường cho tôi.',
      'Tính tiền điện tháng này bao nhiêu?',
      'Trời ơi, đẹp quá!',
      'Mẹ ơi, con về rồi.',
      'Ông bà ấy sống ở quê.',
      // Review I5
      'Để em tính tiền nha.',
      'Anh tính tiền đi.',
      'Chị tính tiền giúp em được không?',
      'Em lấy anh năm 1990.',
      'Anh ấy lấy chị năm 2015.',
      'Dạo này anh mắc lắm.',
      'Hôm nay tôi mắc quá, mai nói chuyện nhé.',
      'Anh ơi là anh!',
      'Ngở ngàng quá trời.',
      'Tôi mua da lô cho con.',
      'Cô ấy đi gia lô về.',
      'Gọi C call cho anh nhé.',
      'Tính tiền thuê nhà tháng này chưa?',
      'Mẹ mắc mưa ngoài đường.',
      'Tôi lấy anh ấy năm 2010.',
      'Anh lấy em hai trăm cái bánh nhé.',
      'Bớt nói lại đi.',
      'Chúng ta ở giữa lòng thành phố.',
      'Nó lo lắng quá.',
      'Ăn quả này đi em.',
      'Uống nước đi.',
      'Đi đâu đó?',
      'Đừng để quên điện thoại.',
      'Cho tôi hỏi tiền phòng bao nhiêu.',
      'Anh ấy là người Singapore.',
    ];
    for (final text in texts) {
      test('keeps "$text"', () {
        expect(engine.forTranslation(text), text);
      });
    }
  });

  group('engine behaviour', () {
    test('every bundled rule has a unique id', () {
      final ids = [
        for (final r in [...pack.recognition, ...pack.beforeTranslation]) r.id,
      ];
      expect(ids.toSet().length, ids.length);
      expect(ids, everyElement(isNotEmpty));
    });

    test('decomposed input is composed before matching', () {
      // "ô kê" typed with combining marks (NFD)
      const nfd = 'ô kê mai gặp nhé';
      expect(engine.fixRecognition(nfd), 'OK mai gặp nhé');
    });

    test('rules match case-insensitively', () {
      expect(engine.fixRecognition('Ở ĐÂY CÓ WIFI'), 'Ở ĐÂY CÓ Wi-Fi');
    });

    test('a pack without rules returns the text untouched', () {
      final none = RuleEngine.forPack(
        LanguagePack.parse(File('assets/languages/en.json').readAsStringSync()),
      );
      expect(none.fixRecognition('  hello  there '), '  hello  there ');
      expect(none.forTranslation('  hello  there '), '  hello  there ');
    });

    test('a rule with a context applies only when the context is present', () {
      final e = RuleEngine(
        recognition: const [],
        beforeTranslation: const [
          Rule(id: 't', pattern: 'mắc', template: 'đắt', context: 'giá'),
        ],
      );
      expect(e.forTranslation('giá mắc'), 'giá đắt');
      expect(e.forTranslation('mắc kẹt'), 'mắc kẹt');
    });

    test('atClauseStart hands the punctuation back as \$1', () {
      final e = RuleEngine(
        recognition: const [],
        beforeTranslation: const [
          Rule(id: 't', pattern: 'xin', template: r'$1 YO', atClauseStart: true),
        ],
      );
      expect(e.forTranslation('Ok, xin chào'), 'Ok, YO chào');
    });

    test('whole words only: a letter or digit touching the match blocks it', () {
      final e = RuleEngine(
        recognition: const [Rule(id: 't', pattern: 'ok', template: 'OK')],
        beforeTranslation: const [],
      );
      expect(e.fixRecognition('ok, book, ok2, ok'), 'OK, book, ok2, OK');
    });
  });

  group('adversarial input', () {
    // Every bundled pattern, as the engine compiles it, on a 2 KB string.
    String big(String unit, {String prefix = ''}) =>
        prefix + unit * ((2048 - prefix.length) ~/ unit.length + 1);
    final subjects = <String, String>{
      'a-pairs': big('a '),
      'a-then-vi': big('a ', prefix: 'ơi ơi ạ ậ ư ờ ẫ ế ệ '),
      'vi-letters': big('ơ ư ạ ậ ế ệ ờ ẫ '),
      'words': big('lấy em một '),
      'digits': big('1 ', prefix: 'lấy anh '),
      'vocative': big('ông bà cô chú anh chị '),
      'repeats': big('tính tiền giùm '),
      'no-spaces': big('a'),
    };
    final engineRules = [...engine.recognitionRules, ...engine.beforeRules];
    for (final rule in engineRules) {
      test('${rule.id} finishes under 50 ms on each adversarial string', () {
        for (final MapEntry(key: name, value: text) in subjects.entries) {
          expect(text.length, greaterThanOrEqualTo(2000), reason: name);
          final sw = Stopwatch()..start();
          rule.context?.hasMatch(text);
          text.replaceAllMapped(rule.regex, (m) => '');
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(50),
            reason: '${rule.id} on $name took ${sw.elapsedMilliseconds} ms',
          );
        }
      });
    }

    test('the whole pipeline is fast too', () {
      for (final text in subjects.values) {
        final sw = Stopwatch()..start();
        engine.forTranslation(text);
        expect(sw.elapsedMilliseconds, lessThan(500));
      }
    });
  });
}
