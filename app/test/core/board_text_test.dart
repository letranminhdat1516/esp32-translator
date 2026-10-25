import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/board_text.dart';
import 'package:live_translator/core/model.dart';

const text = BoardText();
const vi = FontSets.latinVI;
final viExt = FontSets.latinVI | FontSets.latinExtA;

String enc(String s, [FontSets sets = vi]) => text.encode(s, sets);

void main() {
  group('pinned glyph ranges', () {
    // The canonical list (progress.md ruling): today's firmware list with the
    // four single Vietnamese letters absorbed by Latin Extended-A.
    test('latinVI | latinExtA', () {
      expect(text.ranges(viExt), [
        (0x20, 0x7e),
        (0xa0, 0xff),
        (0x100, 0x17f),
        (0x1a0, 0x1a1),
        (0x1af, 0x1b0),
        (0x1ea0, 0x1ef9),
        (0x2013, 0x2014),
        (0x2018, 0x201d),
        (0x2026, 0x2026),
      ]);
    });

    test('latinVI alone is the same list with the Vietnamese singles', () {
      expect(text.ranges(vi), [
        (0x20, 0x7e),
        (0xa0, 0xff),
        (0x102, 0x103),
        (0x110, 0x111),
        (0x128, 0x129),
        (0x168, 0x169),
        (0x1a0, 0x1a1),
        (0x1af, 0x1b0),
        (0x1ea0, 0x1ef9),
        (0x2013, 0x2014),
        (0x2018, 0x201d),
        (0x2026, 0x2026),
      ]);
    });

    test('script sets add their blocks only when their bit is set', () {
      final cjk = text.ranges(vi | FontSets.cjk);
      expect(cjk, containsAll([(0x3000, 0x303f), (0x3040, 0x30ff), (0x4e00, 0x9fff), (0xff00, 0xffef)]));
      final hangul = text.ranges(vi | FontSets.hangul);
      expect(hangul, containsAll([(0x1100, 0x11ff), (0x3130, 0x318f), (0xac00, 0xd7a3)]));
      final thai = text.ranges(vi | FontSets.thai);
      expect(thai, contains((0x0e00, 0x0e7f)));
      // and not otherwise
      expect(text.ranges(viExt).any((r) => r.$1 >= 0x3000), isFalse);
      expect(text.ranges(vi | FontSets.cjk).any((r) => r.$1 >= 0xac00 && r.$1 <= 0xd7a3), isFalse);
      expect(text.ranges(vi | FontSets.hangul).any((r) => r.$1 >= 0x4e00 && r.$1 <= 0x9fff), isFalse);
      expect(text.ranges(vi | FontSets.thai).any((r) => r.$1 == 0x1100), isFalse);
    });

    test('a board that reports nothing is treated as latinVI', () {
      expect(text.ranges(const FontSets.fromInt(0)), text.ranges(vi));
    });

    test('isDrawable follows the ranges', () {
      expect(text.isDrawable(0x1ea1, vi), isTrue); // ạ
      expect(text.isDrawable(0x141, vi), isFalse); // Ł needs Latin Extended-A
      expect(text.isDrawable(0x141, viExt), isTrue);
      expect(text.isDrawable(0x4e2d, vi), isFalse);
      expect(text.isDrawable(0x4e2d, vi | FontSets.cjk), isTrue);
      expect(text.isDrawable(0x20ac, viExt), isFalse); // euro sign
    });
  });

  group('Latin', () {
    test('Vietnamese passes through unchanged', () {
      const s = 'Xin chào, tôi là Việt Nam. Đây là ăn uống: ĩ ũ ơ ư ạ ậ ế ệ ỳ ỹ.';
      expect(enc(s), s);
    });

    test('decomposed input is composed first', () {
      expect(enc('Việt'), 'Việt');
    });

    test('typographic punctuation the board has is kept', () {
      const s = '“Xin chào” – ‘ok’ — hết…';
      expect(enc(s), s);
    });

    test('Latin Extended-A needs its bit, else it is folded to ASCII', () {
      expect(enc('Łódź Žižek Ščerbina'), 'Lódz Zizek Scerbina');
      expect(enc('Łódź Žižek Ščerbina', viExt), 'Łódź Žižek Ščerbina');
    });

    test('letters in neither range are folded when they can be', () {
      expect(enc('café Straße æ ø ǎ ħ ŧ ŋ ı'), 'café Straße æ ø a h t ng i');
    });

    test('symbols with a plain spelling are spelled', () {
      expect(enc('10 € → 5™'), '10 EUR -> 5TM');
      expect(enc('a−b'), 'a-b');
    });

    test('whitespace and control characters collapse to single spaces', () {
      expect(enc(' a \n\n b\t\u00a0c  '), 'a b c');
    });

    test('digits of other scripts become ASCII digits', () {
      expect(enc('١٢٣ १२'), '123 12');
    });
  });

  group('Cyrillic and Greek are transliterated', () {
    test('Russian', () {
      expect(enc('Привет, мир'), 'Privet, mir');
      expect(enc('Москва'), 'Moskva');
      expect(enc('Щука'), 'Shchuka');
      expect(enc('ЖУК'), 'ZHUK');
      expect(enc('Ёлка'), 'Yolka');
    });

    test('Ukrainian and Serbian letters', () {
      expect(enc('Україна'), 'Ukrayina');
      expect(enc('Європа'), 'Yevropa');
      expect(enc('Љубљана'), 'Ljubljana');
    });

    test('Greek', () {
      expect(enc('Καλημέρα κόσμε'), 'Kalimera kosme');
      expect(enc('Ελλάδα'), 'Ellada');
      expect(enc('ουρανός'), 'ouranos');
      expect(enc('Αθήνα'), 'Athina');
    });

    test('also when the board has CJK, Hangul and Thai', () {
      final all = viExt | FontSets.cjk | FontSets.hangul | FontSets.thai;
      expect(enc('Привет', all), 'Privet');
      expect(enc('Αθήνα', all), 'Athina');
    });
  });

  group('Japanese kana without the cjk font', () {
    test('hiragana and katakana become romaji', () {
      expect(enc('こんにちは'), 'konnichiha');
      expect(enc('ありがとう'), 'arigatou');
      expect(enc('カタカナ'), 'katakana');
      expect(enc('ラーメン'), 'ramen');
      expect(enc('きょう'), 'kyou');
      expect(enc('しゃしん'), 'shashin');
      expect(enc('ちゃ'), 'cha');
      expect(enc('じゅう'), 'juu');
      expect(enc('がっこう'), 'gakkou');
      expect(enc('まっちゃ'), 'matcha');
      expect(enc('ほんや'), "hon'ya");
      expect(enc('ぱぴぷぺぽ'), 'papipupepo');
      expect(enc('ＡＢＣ'), 'ABC');
    });

    test('Han characters in kana text become a dot', () {
      expect(enc('東京に行く'), '·ni·ku');
      expect(enc('東京 に 行く'), '· ni ·ku');
    });

    test('Japanese punctuation is spelled', () {
      expect(enc('はい、そうです。'), 'hai, soudesu.');
      expect(enc('「はい」'), '"hai"');
    });

    test('with the cjk font the text is left alone', () {
      const s = '東京に行く。こんにちは、ラーメン';
      expect(enc(s, vi | FontSets.cjk), s);
    });
  });

  group('scripts with no table', () {
    test('Han becomes a dot per word', () {
      expect(enc('你好'), '·');
      expect(enc('你好 世界'), '· ·');
    });

    test('Hangul and Thai become a dot per word without their font', () {
      expect(enc('안녕하세요 세계'), '· ·');
      expect(enc('สวัสดี ครับ'), '· ·');
      expect(enc('안녕 세계', vi | FontSets.hangul), '안녕 세계');
      expect(enc('สวัสดี', vi | FontSets.thai), 'สวัสดี');
    });

    test('the bit of another script does not help', () {
      expect(enc('안녕', vi | FontSets.cjk), '·');
      expect(enc('你好', vi | FontSets.hangul), '·');
      expect(enc('你好', vi | FontSets.thai), '·');
    });

    test('Arabic and Hebrew get a dot', () {
      expect(enc('مرحبا'), '·');
      expect(enc('שלום'), '·');
    });

    test('mixed words keep what can be drawn', () {
      expect(enc('Hello 世界'), 'Hello ·');
      expect(enc('東京Tower'), '·Tower');
      expect(enc('你好, thế giới!'), '·, thế giới!');
    });

    test('runs of undrawable letters make one dot', () {
      expect(enc('你好世界吗'), '·');
      expect(enc('a你好b世界c'), 'a·b·c');
    });

    test('fullwidth forms fold to ASCII without the cjk font', () {
      expect(enc('ＡＢＣ１２３！'), 'ABC123!');
      expect(enc('ＡＢＣ', vi | FontSets.cjk), 'ＡＢＣ');
    });
  });

  group('never empty', () {
    test('emoji and symbols alone give a dot', () {
      expect(enc('😀'), '·');
      expect(enc('☃ \u{1F680}'), '·');
    });

    test('emoji among words are dropped', () {
      expect(enc('Hi 😀 there'), 'Hi there');
    });

    test('blank input stays blank: there is nothing to show', () {
      expect(enc(''), '');
      expect(enc('  \n '), '');
    });

    test('every non-blank sample gives output the board can draw', () {
      const samples = [
        'Xin chào', 'Привет', 'Καλημέρα', 'こんにちは', '東京', '안녕', 'สวัสดี', 'مرحبا',
        '😀', 'a\u0000b', '\u202e', '\u200b', '́', 'ǅ', 'ﬁ', '①', '½', 'ǆ', '￿',
        'x\u{10FFFF}', 'Ｈｅｌｌｏ', 'ｱｲｳ', '€100', 'Ελλάς Ελλάδα', 'Tiếng Việt – đẹp',
      ];
      final setsList = [
        vi,
        viExt,
        vi | FontSets.cjk,
        viExt | FontSets.cjk | FontSets.hangul | FontSets.thai,
        const FontSets.fromInt(0),
      ];
      for (final sets in setsList) {
        for (final s in samples) {
          final out = text.encode(s, sets);
          expect(out, isNotEmpty, reason: '$s with $sets');
          for (final cp in out.runes) {
            expect(
              cp == 0x20 || text.isDrawable(cp, sets),
              isTrue,
              reason: 'U+${cp.toRadixString(16)} from "$s" with $sets',
            );
          }
          expect(out, out.trim());
          expect(out.contains('  '), isFalse);
        }
      }
    });
  });
}
