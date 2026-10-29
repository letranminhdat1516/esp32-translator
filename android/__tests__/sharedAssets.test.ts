// The bundled copies of shared/ (src/shared-generated, written by scripts/sync-shared.mjs) must
// equal shared/ itself: packs and glyph lists are loaded, never edited by hand.
import fs from 'fs';
import path from 'path';

import {
  boardGlyphTexts,
  bundledPack,
  bundledPackCodes,
  bundledPacks,
  translitTables,
} from '../src/core/sharedAssets';
import {loadFixture, readPackJson, sharedDir, shippedPackCodes} from './fixtures';

describe('sharedAssets', () => {
  test('every shared/languages pack is bundled, as the same JSON', () => {
    expect(bundledPackCodes()).toEqual(shippedPackCodes());
    for (const code of shippedPackCodes()) {
      expect(bundledPack(code)).toEqual(
        expect.objectContaining({code: JSON.parse(readPackJson(code)).code}),
      );
    }
  });

  test('bundled packs parse once, one per shared/languages file', () => {
    const packs = bundledPacks();
    expect(packs.map(p => p.code).sort()).toEqual(shippedPackCodes());
    expect(bundledPacks()).toBe(packs); // parsed once
  });

  test('an unknown code has no bundled pack', () => {
    expect(bundledPack('xx')).toBeNull();
  });

  test('glyph lists are byte-identical to shared/board_glyphs', () => {
    for (const name of ['cjk', 'hangul', 'thai'] as const) {
      expect(boardGlyphTexts[name]).toBe(
        fs.readFileSync(path.join(sharedDir, 'board_glyphs', `${name}.txt`), 'utf8'),
      );
    }
  });

  test('translit tables equal shared/fixtures/translit.json', () => {
    expect(translitTables).toEqual(loadFixture('translit'));
  });

  test('the generated pack data equals shared/languages', () => {
    const generated = JSON.parse(
      fs.readFileSync(path.join(__dirname, '../src/shared-generated/languages.json'), 'utf8'),
    );
    const expected: Record<string, unknown> = {};
    for (const code of shippedPackCodes()) {
      expected[code] = JSON.parse(readPackJson(code));
    }
    expect(generated).toEqual(expected);
  });
});
