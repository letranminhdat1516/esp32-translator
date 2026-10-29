/* eslint-disable no-bitwise -- byte-level protocol */
// Port of app/lib/board/protocol.dart: the subtitle board's BLE protocol, byte-compatible with the
// firmware and ios/Sources/BLE/ESPLink.swift. Contract: shared/fixtures/protocol.json.
import {BoardInfo, FontSets} from '../core/model';

/** GATT service of the subtitle board. */
export const boardServiceUuid = 'A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A';
/** Notify: audio packets from the board mic. */
export const boardAudioUuid = 'A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A';
/** Write: text chunks `[flags][kind][payload]`. */
export const boardTextUuid = 'A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A';
/** Write: mic on/off and keepalive; notify: mic state changes. */
export const boardControlUuid = 'A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A';
/** Read: `[version u8][fontSets u32 LE]`. Absent on older firmware. */
export const boardInfoUuid = 'A7C00005-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/** What the board does with a text chunk (its second byte). */
export type TextKind = 'subtitle' | 'status' | 'time' | 'label';
export const textKinds: readonly TextKind[] = ['subtitle', 'status', 'time', 'label'];
export const textKindCodes: Readonly<Record<TextKind, number>> = {
  subtitle: 0,
  status: 1,
  time: 2,
  label: 3,
};

/** The round screen shows about 5 lines, so only this many bytes are sent. */
export const maxTextBytes = 150;
/** Longest label the board accepts (UTF-8 bytes). */
export const maxLabelBytes = 32;

// --- UTF-8 and grapheme clusters --------------------------------------------

/** UTF-8 bytes of `text`; a lone surrogate becomes U+FFFD (as `TextEncoder` does). */
export function utf8Encode(text: string): Uint8Array {
  const out: number[] = [];
  for (const ch of text) {
    let cp = ch.codePointAt(0) as number;
    if (cp >= 0xd800 && cp <= 0xdfff) {
      cp = 0xfffd;
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f),
      );
    }
  }
  return Uint8Array.from(out);
}

function utf8Length(text: string): number {
  let n = 0;
  for (const ch of text) {
    const cp = ch.codePointAt(0) as number;
    n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
  }
  return n;
}

const markRe = /\p{M}/u;
const spacingMarkRe = /\p{Mc}/u;
const controlRe = /[\p{Cc}\p{Zl}\p{Zp}\p{Cf}]/u;
const extPictRe = ((): RegExp | null => {
  try {
    return new RegExp('\\p{Extended_Pictographic}', 'u');
  } catch {
    return null; // an engine without the property: see isExtPict
  }
})();

const inRange = (cp: number, lo: number, hi: number) => cp >= lo && cp <= hi;
const isRegionalIndicator = (cp: number) => inRange(cp, 0x1f1e6, 0x1f1ff);
const isExtPict = (ch: string, cp: number) => (extPictRe ? extPictRe.test(ch) : cp >= 0x1f000);

// Hangul syllable types (GB6–GB8).
const isL = (cp: number) => inRange(cp, 0x1100, 0x115f) || inRange(cp, 0xa960, 0xa97c);
const isV = (cp: number) => inRange(cp, 0x1160, 0x11a7) || inRange(cp, 0xd7b0, 0xd7c6);
const isT = (cp: number) => inRange(cp, 0x11a8, 0x11ff) || inRange(cp, 0xd7cb, 0xd7fb);
const isSyllable = (cp: number) => inRange(cp, 0xac00, 0xd7a3);
const isLV = (cp: number) => isSyllable(cp) && (cp - 0xac00) % 28 === 0;
const isLVT = (cp: number) => isSyllable(cp) && (cp - 0xac00) % 28 !== 0;

/** GB9c linkers of Unicode 15.1 (Indic_Conjunct_Break=Linker): the viramas of six scripts. */
const conjunctLinkers: ReadonlySet<number> = new Set([0x94d, 0x9cd, 0xacd, 0xb4d, 0xc4d, 0xd4d]);
/** Indic_Conjunct_Break=Consonant: Devanagari, Bengali, Gujarati, Oriya, Telugu, Malayalam. */
const conjunctConsonants: ReadonlyArray<readonly [number, number]> = [
  [0x915, 0x939], [0x958, 0x95f], [0x978, 0x97f],
  [0x995, 0x9a8], [0x9aa, 0x9b0], [0x9b2, 0x9b2], [0x9b6, 0x9b9], [0x9dc, 0x9dd],
  [0x9df, 0x9df], [0x9f0, 0x9f1],
  [0xa95, 0xaa8], [0xaaa, 0xab0], [0xab2, 0xab3], [0xab5, 0xab9], [0xaf9, 0xaf9],
  [0xb15, 0xb28], [0xb2a, 0xb30], [0xb32, 0xb33], [0xb35, 0xb39], [0xb5c, 0xb5d],
  [0xb5f, 0xb5f], [0xb71, 0xb71],
  [0xc15, 0xc28], [0xc2a, 0xc39], [0xc58, 0xc5a],
  [0xd15, 0xd3a],
];
const isConsonant = (cp: number) => conjunctConsonants.some(([lo, hi]) => inRange(cp, lo, hi));

/** Grapheme_Cluster_Break Extend, ZWJ or SpacingMark (GB9, GB9a), including Thai and Lao AM. */
function isExtend(ch: string, cp: number): boolean {
  return (
    markRe.test(ch) ||
    cp === 0x200c ||
    cp === 0x200d ||
    cp === 0xe33 ||
    cp === 0xeb3 ||
    inRange(cp, 0x1f3fb, 0x1f3ff) ||
    inRange(cp, 0xe0020, 0xe007f)
  );
}

const isControl = (ch: string, cp: number) =>
  cp === 0x0d || cp === 0x0a || (controlRe.test(ch) && !isExtend(ch, cp));

/**
 * Grapheme clusters of board text: UAX #29 extended grapheme clusters as Dart's `characters` and
 * Swift's `Character` give them (GB9c conjuncts only for the six Unicode 15.1 linker scripts).
 * Deliberately not `Intl.Segmenter`, whose answer follows the engine's Unicode version (ICU 78
 * also joins Khmer and Myanmar conjuncts; Dart and Swift do not). Simplifications: no Prepend
 * (GB9b); GB11 joins a pictographic after any ZWJ.
 */
export function graphemes(text: string): string[] {
  const out: string[] = [];
  let prev = -1;
  let prevCh = '';
  let riRun = 0;
  // GB9c state: 0 none, 1 after a consonant (+ extends), 2 a linker followed it.
  let conjunct = 0;
  for (const ch of text) {
    const cp = ch.codePointAt(0) as number;
    let join: boolean;
    if (out.length === 0) {
      join = false;
    } else if (prev === 0x0d && cp === 0x0a) {
      join = true; // GB3
    } else if (isControl(prevCh, prev) || isControl(ch, cp)) {
      join = false; // GB4, GB5
    } else if (isL(prev) && (isL(cp) || isV(cp) || isSyllable(cp))) {
      join = true; // GB6
    } else if ((isLV(prev) || isV(prev)) && (isV(cp) || isT(cp))) {
      join = true; // GB7
    } else if ((isLVT(prev) || isT(prev)) && isT(cp)) {
      join = true; // GB8
    } else if (isExtend(ch, cp)) {
      join = true; // GB9, GB9a
    } else if (conjunct === 2 && isConsonant(cp)) {
      join = true; // GB9c
    } else if (prev === 0x200d && isExtPict(ch, cp)) {
      join = true; // GB11
    } else {
      join = isRegionalIndicator(cp) && riRun % 2 === 1; // GB12, GB13
    }
    if (join) {
      out[out.length - 1] += ch;
    } else {
      out.push(ch);
    }
    if (isConsonant(cp)) {
      conjunct = 1;
    } else if (conjunctLinkers.has(cp)) {
      conjunct = conjunct > 0 ? 2 : 0;
    } else if (!(cp === 0x200d || (markRe.test(ch) && !spacingMarkRe.test(ch)))) {
      conjunct = 0; // only non-spacing marks and ZWJ keep a conjunct open
    }
    riRun = isRegionalIndicator(cp) ? riRun + 1 : 0;
    prev = cp;
    prevCh = ch;
  }
  return out;
}

// --- framing ------------------------------------------------------------------

/**
 * Mirrors `ESPLink.tail(of:maxBytes:)`: keeps the tail of `text` within `maxTextBytes`, never
 * splitting a grapheme cluster, then drops the partial word up to the first space and prefixes "…".
 */
function tail(text: string): string {
  if (utf8Length(text) <= maxTextBytes) {
    return text;
  }
  const chars = graphemes(text);
  let bytes = utf8Length(text);
  let start = 0;
  while (bytes > maxTextBytes) {
    bytes -= utf8Length(chars[start]);
    start++;
  }
  let rest = chars.slice(start);
  const space = rest.indexOf(' ');
  if (space >= 0) {
    rest = rest.slice(space + 1);
  }
  return `…${rest.join('')}`;
}

/**
 * Splits `text` into the chunks written to the text characteristic (`ESPLink.send`). `maxWrite`
 * is the peripheral's maximum write-without-response length; the payload per chunk is
 * `max(20, maxWrite) - 2`. Chunk = `[flags][kind][payload]`, flags bit0 first chunk, bit1 last
 * chunk. There is always at least one chunk.
 */
export function frameText(
  text: string,
  kind: TextKind,
  maxWrite: number,
): Uint8Array[] {
  const payload = utf8Encode(tail(text));
  const size = Math.max(20, maxWrite) - 2;
  const chunks: Uint8Array[] = [];
  let offset = 0;
  do {
    const end = Math.min(offset + size, payload.length);
    const flags = (offset === 0 ? 0x01 : 0) | (end === payload.length ? 0x02 : 0);
    const chunk = new Uint8Array(2 + end - offset);
    chunk[0] = flags;
    chunk[1] = textKindCodes[kind];
    chunk.set(payload.subarray(offset, end), 2);
    chunks.push(chunk);
    offset = end;
  } while (offset < payload.length);
  return chunks;
}

/**
 * Payload of the clock message: `"<unix seconds> <UTC offset minutes>"`. The offset defaults to
 * the device's for that instant.
 */
export function timeText(
  now: Date,
  utcOffsetMinutes: number = -now.getTimezoneOffset(),
): string {
  return `${Math.floor(now.getTime() / 1000)} ${utcOffsetMinutes + 0}`;
}

/** The clock message as one chunk (flags 0x03, kind 2), like `ESPLink.timePayload`. */
export function timeFrame(now: Date): Uint8Array {
  const text = utf8Encode(timeText(now));
  const frame = new Uint8Array(2 + text.length);
  frame[0] = 0x03;
  frame[1] = textKindCodes.time;
  frame.set(text, 2);
  return frame;
}

/** Cuts `label` to at most `maxLabelBytes` UTF-8 bytes at a character boundary, no ellipsis. */
export function labelText(label: string): string {
  let bytes = 0;
  let out = '';
  for (const ch of graphemes(label)) {
    const n = utf8Length(ch);
    if (bytes + n > maxLabelBytes) {
      break;
    }
    bytes += n;
    out += ch;
  }
  return out;
}

/** Parses the board-info characteristic `[version u8][fontSets u32 LE]`; null when shorter than 5 bytes. */
export function parseBoardInfo(data: Uint8Array): BoardInfo | null {
  if (data.length < 5) {
    return null;
  }
  const sets = (data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24)) >>> 0;
  return {protocolVersion: data[0], fontSets: FontSets.fromInt(sets)};
}
