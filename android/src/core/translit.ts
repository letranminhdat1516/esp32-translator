// Port of app/lib/core/translit.dart. The tables are not copied: they are the data of
// shared/fixtures/translit.json (exported from translit.dart, the source of truth), bundled through
// sharedAssets.ts; the rules below are README "translit.json" and board_text.json checks them.
//
// The board can only draw the scripts whose font sets it reports: Cyrillic and Greek always come
// out in Latin letters; Japanese kana does when the board has no CJK font. Han, Hangul, Thai and the
// rest have no table.
import {translitTables, type TranslitTables} from './sharedAssets';

const tables: TranslitTables = translitTables;
const own = (o: object, k: string): boolean => Object.prototype.hasOwnProperty.call(o, k);
const lookup = (o: Readonly<Record<string, string>>, k: string): string | null =>
  own(o, k) ? o[k] : null;

/** Characters the board cannot draw, spelled with ones it can. A space means "separate the words". */
export const punctuation: Readonly<Record<string, string>> = tables.punctuation;

/** True for a letter `translitLetter` can turn into Latin. */
export function hasLetterTable(cp: number): boolean {
  return translitLetter(cp) !== null;
}

/**
 * Latin spelling of a Cyrillic or Greek letter, or null for any other character. A capital gives a
 * capital first letter (`Ж` -> `Zh`), or the whole spelling in capitals when `allCaps` (the word is
 * all capitals). `afterOmicron` spells upsilon as `u` (the diphthong `ου`).
 */
export function translitLetter(
  cp: number,
  {allCaps = false, afterOmicron = false}: {allCaps?: boolean; afterOmicron?: boolean} = {},
): string | null {
  const ch = String.fromCodePoint(cp);
  const lower = ch.toLowerCase();
  const isUpper = lower !== ch;
  let latin = lookup(tables.cyrillic, lower) ?? lookup(tables.greek, lower);
  if (latin === null) {
    return null;
  }
  const u = tables.upsilonAfterOmicron;
  if (afterOmicron && u.letters.includes(lower)) {
    latin = u.latin;
  }
  if (!isUpper || latin === '') {
    return latin;
  }
  return allCaps ? latin.toUpperCase() : latin[0].toUpperCase() + latin.slice(1);
}

/** True for Greek omicron, with or without tonos, either case. */
export function isOmicron(cp: number): boolean {
  const c = String.fromCodePoint(cp);
  const omicrons = tables.upsilonAfterOmicron.omicrons;
  return omicrons.includes(c) || omicrons.includes(c.toLowerCase());
}

/** ASCII spelling of a Latin letter with no decomposition that the board cannot draw, or null. */
export function latinSpecial(char: string): string | null {
  return lookup(tables.latinSpecial, char);
}

/** ASCII digit for a decimal digit of another script, or null. */
export function asciiDigit(cp: number): string | null {
  for (const zero of tables.digitZeros) {
    if (cp >= zero && cp <= zero + 9) {
      return String.fromCharCode(0x30 + cp - zero);
    }
  }
  return null;
}

// --- Japanese kana -> romaji (Hepburn) ------------------------------------------------------

const kana = tables.kana;

/** True for hiragana, katakana, the long-vowel mark and the iteration marks. */
export function isKana(cp: number): boolean {
  return kana.isKana.some(([lo, hi]) => cp >= lo && cp <= hi);
}

/** Hiragana for a kana code point (katakana maps onto hiragana by a fixed offset), or null. */
function toHiragana(cp: number): string | null {
  const [hLo, hHi] = kana.hiraganaRange;
  const [kLo, kHi] = kana.katakanaRange;
  if (cp >= hLo && cp <= hHi) {
    return String.fromCodePoint(cp);
  }
  if (cp >= kLo && cp <= kHi) {
    return String.fromCodePoint(cp - kana.katakanaOffset);
  }
  return null;
}

/**
 * Reads the kana (plus any small kana that joins it) at `i` in `runes`. Returns the romaji and how
 * many code points it used, or null when `runes` holds no readable kana there.
 */
export function readKana(runes: readonly number[], i: number): [string, number] | null {
  const cp = runes[i];
  if (kana.silent.includes(String.fromCodePoint(cp))) {
    return ['', 1];
  }
  const c = toHiragana(cp);
  if (c === null) {
    return null;
  }
  if (c === kana.sokuon) {
    // doubles the next consonant
    const next = i + 1 < runes.length ? readKana(runes, i + 1) : null;
    if (next === null || next[0] === '') {
      return ['', 1];
    }
    const first = next[0][0];
    if ('aiueon'.includes(first)) {
      return [next[0], 1 + next[1]];
    }
    const doubled = next[0].startsWith('ch') ? 't' : first;
    return [doubled + next[0], 1 + next[1]];
  }
  if (c === kana.n) {
    const next = i + 1 < runes.length ? toHiragana(runes[i + 1]) : null;
    return [next !== null && kana.nApostropheBefore.includes(next) ? "n'" : 'n', 1];
  }
  const small = lookup(kana.smallY, c);
  if (small !== null) {
    return [`y${small}`, 1];
  }
  const base = lookup(kana.hiragana, c);
  if (base === null) {
    return null;
  }
  if (i + 1 < runes.length && base.length >= 2 && base.endsWith('i')) {
    const nextHiragana = toHiragana(runes[i + 1]);
    const joined = nextHiragana === null ? null : lookup(kana.smallY, nextHiragana);
    if (joined !== null) {
      const stem = base.slice(0, -1);
      const combined = stem === 'sh' || stem === 'ch' || stem === 'j' ? stem + joined : `${stem}y${joined}`;
      return [combined, 2];
    }
  }
  return [base, 1];
}
