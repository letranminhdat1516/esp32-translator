// The data in shared/ as the app bundles it: language packs, the board's glyph lists and the
// transliteration tables. Metro cannot import from outside android/ nor import .txt files, so
// `npm run sync-shared` copies them into src/shared-generated/ as JSON; that folder is committed
// so a plain Gradle/Metro build needs no extra step. `npm test` stops first (`pretest`,
// `sync-shared --check`) and __tests__/sharedAssets.test.ts fails when it no longer equals shared/.
import boardGlyphsJson from '../shared-generated/boardGlyphs.json';
import languagesJson from '../shared-generated/languages.json';
import translitJson from '../shared-generated/translit.json';
import {languagePackFromJson, type LanguagePack} from './model';

/** The text of `shared/board_glyphs/<set>.txt` (one `XXXX` or `XXXX-YYYY` hex per line). */
export interface BoardGlyphTexts {
  readonly cjk: string;
  readonly hangul: string;
  readonly thai: string;
}

/** `shared/fixtures/translit.json`: the tables of `app/lib/core/translit.dart` as data. */
export interface TranslitTables {
  readonly cyrillic: Readonly<Record<string, string>>;
  readonly greek: Readonly<Record<string, string>>;
  readonly upsilonAfterOmicron: {
    readonly letters: readonly string[];
    readonly latin: string;
    readonly omicrons: readonly string[];
  };
  readonly latinSpecial: Readonly<Record<string, string>>;
  readonly punctuation: Readonly<Record<string, string>>;
  readonly digitZeros: readonly number[];
  readonly kana: {
    readonly hiraganaRange: readonly [number, number];
    readonly katakanaRange: readonly [number, number];
    readonly katakanaOffset: number;
    readonly hiragana: Readonly<Record<string, string>>;
    readonly smallY: Readonly<Record<string, string>>;
    readonly sokuon: string;
    readonly n: string;
    readonly nApostropheBefore: readonly string[];
    readonly silent: readonly string[];
    readonly isKana: readonly (readonly [number, number])[];
  };
}

export const boardGlyphTexts: BoardGlyphTexts = boardGlyphsJson;

export const translitTables: TranslitTables = translitJson as unknown as TranslitTables;

const packJson = languagesJson as unknown as Readonly<Record<string, {[key: string]: unknown}>>;

let parsed: readonly LanguagePack[] | null = null;

/** Codes of the bundled packs, sorted. */
export function bundledPackCodes(): string[] {
  return Object.keys(packJson).sort();
}

/** Every bundled pack, parsed (and validated) once, in code order. Throws `PackError` if one is bad. */
export function bundledPacks(): readonly LanguagePack[] {
  parsed ??= Object.freeze(bundledPackCodes().map(code => languagePackFromJson(packJson[code])));
  return parsed;
}

/** The bundled pack `code`, or null when there is none. */
export function bundledPack(code: string): LanguagePack | null {
  return bundledPacks().find(p => p.code === code) ?? null;
}
