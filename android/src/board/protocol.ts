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

/** Splits text into user-perceived characters (grapheme clusters). */
export type Graphemes = (text: string) => string[];

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
const isRegionalIndicator = (cp: number) => cp >= 0x1f1e6 && cp <= 0x1f1ff;

/**
 * Grapheme clusters without `Intl.Segmenter` (Hermes may not have it). An approximation of
 * UAX #29 that covers what subtitles carry: CR LF, combining marks and variation selectors,
 * emoji modifiers, ZWJ sequences, flag pairs, conjoining Hangul vowel/final jamo, tag characters.
 */
export function fallbackGraphemes(text: string): string[] {
  const out: string[] = [];
  let prev = -1;
  let riRun = 0;
  for (const ch of text) {
    const cp = ch.codePointAt(0) as number;
    const ri = isRegionalIndicator(cp);
    const extend =
      out.length > 0 &&
      prev !== 0x0a &&
      ((prev === 0x0d && cp === 0x0a) ||
        (prev !== 0x0d &&
          (markRe.test(ch) ||
            cp === 0x200d ||
            prev === 0x200d ||
            (cp >= 0x1f3fb && cp <= 0x1f3ff) ||
            (cp >= 0x1160 && cp <= 0x11ff) ||
            (cp >= 0xd7b0 && cp <= 0xd7ff) ||
            (cp >= 0xe0020 && cp <= 0xe007f) ||
            (ri && riRun % 2 === 1))));
    if (extend) {
      out[out.length - 1] += ch;
    } else {
      out.push(ch);
    }
    riRun = ri ? riRun + 1 : 0;
    prev = cp;
  }
  return out;
}

type SegmenterCtor = new (
  locale?: string,
  options?: {granularity: 'grapheme'},
) => {segment(text: string): Iterable<{segment: string}>};

const segmenterCtor = (globalThis as {Intl?: {Segmenter?: SegmenterCtor}}).Intl?.Segmenter;
const segmenter = segmenterCtor ? new segmenterCtor(undefined, {granularity: 'grapheme'}) : null;

/** `Intl.Segmenter` when the engine has it, else `fallbackGraphemes`. */
export const defaultGraphemes: Graphemes = segmenter
  ? text => Array.from(segmenter.segment(text), s => s.segment)
  : fallbackGraphemes;

// --- framing ------------------------------------------------------------------

/**
 * Mirrors `ESPLink.tail(of:maxBytes:)`: keeps the tail of `text` within `maxTextBytes`, never
 * splitting a grapheme cluster, then drops the partial word up to the first space and prefixes "…".
 */
function tail(text: string, graphemes: Graphemes): string {
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
  graphemes: Graphemes = defaultGraphemes,
): Uint8Array[] {
  const payload = utf8Encode(tail(text, graphemes));
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
export function labelText(label: string, graphemes: Graphemes = defaultGraphemes): string {
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
