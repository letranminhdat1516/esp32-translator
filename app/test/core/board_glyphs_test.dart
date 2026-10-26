import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/board_glyphs.dart';
import 'package:live_translator/core/board_text.dart';
import 'package:live_translator/core/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(BoardGlyphSets.resetShared);
  tearDown(BoardGlyphSets.resetShared);

  test('shared throws until the assets are loaded', () {
    expect(() => BoardGlyphSets.shared, throwsStateError);
    expect(() => const BoardText().isDrawable(0x4e2d, FontSets.cjk), throwsStateError);
    // No extra font: no lists needed.
    expect(const BoardText().isDrawable(0x41, FontSets.latinVI), isTrue);
  });

  test('load reads the declared assets once and BoardText uses them by default', () async {
    final loaded = await BoardGlyphSets.load();
    expect(await BoardGlyphSets.load(), same(loaded));
    expect(BoardGlyphSets.shared, same(loaded));
    const text = BoardText();
    final sets = FontSets.latinVI | FontSets.cjk | FontSets.hangul | FontSets.thai;
    expect(text.isDrawable(0x4e2d, sets), isTrue);
    expect(text.isDrawable(0xac00, sets), isTrue);
    expect(text.isDrawable(0x0e01, sets), isTrue);
    expect(text.isDrawable(0x4e02, sets), isFalse);
    expect(text.encode('中丂文', sets), '中·文');
  });
}
