/* eslint-disable no-bitwise -- FontSets is a bit mask */
// Port of app/lib/core/model.dart: language packs (shared/languages/*.json), board font sets,
// engine capabilities and board info. Contract: shared/fixtures/model.json.
//
// Values are plain readonly objects, so `JSON.stringify(pack)` gives the pack JSON format back
// (the Dart `toJson`). Equality helpers replace Dart's `==` where callers need it.

/** Writing system a language is displayed in; decides which board font set is needed. */
export type Script = 'latin' | 'cjk' | 'hangul' | 'thai' | 'cyrillic' | 'other';
/** Every `Script`, in the Dart enum order. */
export const scripts: readonly Script[] = ['latin', 'cjk', 'hangul', 'thai', 'cyrillic', 'other'];

/**
 * Thrown by `parseLanguagePack` when a pack is malformed. `field` is the path of the offending
 * field, e.g. `label` or `recognition[0].pattern` (`''` for the whole document); `field` and
 * `reason` are the Dart texts.
 */
export class PackError extends Error {
  constructor(readonly field: string, readonly reason: string) {
    super(`PackError(${field}): ${reason}`);
    this.name = 'PackError';
  }

  toString(): string {
    return this.message;
  }
}

/** Bit mask of the glyph sets the board firmware has fonts for (the BLE `fontSets` u32). */
export class FontSets {
  /** Bit 1: Basic Latin plus the Vietnamese letters and tone marks. */
  static readonly latinVI = new FontSets(1);
  /** Bit 2: Latin Extended-A, U+0100-U+017F, in addition to latinVI. */
  static readonly latinExtA = new FontSets(2);
  /** Bit 4: CJK ideographs plus Japanese kana. */
  static readonly cjk = new FontSets(4);
  /** Bit 8: Korean Hangul syllables. */
  static readonly hangul = new FontSets(8);
  /** Bit 16: Thai. */
  static readonly thai = new FontSets(16);

  /** The mask as an unsigned 32-bit integer. */
  readonly value: number;

  private constructor(value: number) {
    this.value = value >>> 0;
  }

  /** Builds a set from a raw bitmask (e.g. the BLE `fontSets` u32). */
  static fromInt(value: number): FontSets {
    return new FontSets(value);
  }

  /** Dart `|`. */
  or(other: FontSets): FontSets {
    return new FontSets(this.value | other.value);
  }

  /** True when every bit of `other` is set in this set. */
  contains(other: FontSets): boolean {
    return ((this.value & other.value) >>> 0) === other.value;
  }

  /**
   * True when the board can render text written in `script`. Cyrillic and other scripts have no
   * board font and are never covered.
   */
  covers(script: Script): boolean {
    switch (script) {
      case 'latin':
        return this.contains(FontSets.latinVI) || this.contains(FontSets.latinExtA);
      case 'cjk':
        return this.contains(FontSets.cjk);
      case 'hangul':
        return this.contains(FontSets.hangul);
      case 'thai':
        return this.contains(FontSets.thai);
      case 'cyrillic':
      case 'other':
        return false;
    }
  }

  equals(other: FontSets): boolean {
    return other.value === this.value;
  }

  toString(): string {
    return `FontSets(${this.value})`;
  }
}

export interface Rule {
  readonly id: string;
  readonly pattern: string;
  readonly template: string;
  readonly atClauseStart: boolean;
  /** Absent when the rule applies everywhere. */
  readonly context?: string;
}

export type TermOrigin = 'builtIn' | 'user';
export const termOrigins: readonly TermOrigin[] = ['builtIn', 'user'];

export interface Term {
  readonly id: string;
  readonly text: string;
  readonly variants: readonly string[];
  /** Fixed translation per target language code. */
  readonly fixed: Readonly<Record<string, string>>;
  readonly origin: TermOrigin;
}

export interface LanguagePack {
  /** BCP-47: "ja", "fr", "zh-Hans". */
  readonly code: string;
  readonly appleLocale: string;
  readonly androidLocale: string;
  readonly whisperCode: string;
  readonly label: string;
  readonly labelLatin: string;
  readonly script: Script;
  /** Their-side gate; null when the pack sets none. */
  readonly minConfidence: number | null;
  readonly recognition: readonly Rule[];
  readonly beforeTranslation: readonly Rule[];
  readonly terms: readonly Term[];
  readonly hints: readonly string[];
}

export type RecognizerKind = 'osOnDevice' | 'whisper' | 'osOnline';
/** Every `RecognizerKind`, in the Dart enum order (also the recognizer chain order). */
export const recognizerKinds: readonly RecognizerKind[] = ['osOnDevice', 'whisper', 'osOnline'];

export interface Capabilities {
  /** Recognizers available per language code, best first. */
  readonly recognizers: Readonly<Record<string, readonly RecognizerKind[]>>;
  /** Language codes the device can translate to or from. */
  readonly translatable: ReadonlySet<string>;
  readonly vietnameseVoice: boolean;
}

export interface BoardInfo {
  readonly protocolVersion: number;
  readonly fontSets: FontSets;
}

/** What a board without the `…0005` characteristic (older firmware) can render. */
export const legacyBoardInfo: BoardInfo = {protocolVersion: 0, fontSets: FontSets.latinVI};

export function capabilitiesEquals(a: Capabilities, b: Capabilities): boolean {
  if (a.vietnameseVoice !== b.vietnameseVoice) {
    return false;
  }
  if (a.translatable.size !== b.translatable.size) {
    return false;
  }
  for (const code of a.translatable) {
    if (!b.translatable.has(code)) {
      return false;
    }
  }
  const aKeys = Object.keys(a.recognizers);
  if (aKeys.length !== Object.keys(b.recognizers).length) {
    return false;
  }
  return aKeys.every(k => {
    const x = a.recognizers[k];
    const y = b.recognizers[k];
    return y !== undefined && x.length === y.length && x.every((v, i) => v === y[i]);
  });
}

export function boardInfoEquals(a: BoardInfo, b: BoardInfo): boolean {
  return a.protocolVersion === b.protocolVersion && a.fontSets.equals(b.fontSets);
}

// --- parsing ---------------------------------------------------------------

type JsonMap = {[key: string]: unknown};

const isMap = (v: unknown): v is JsonMap =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Parses and validates pack JSON. Throws `PackError` on invalid JSON, a missing or mistyped field,
 * or a pattern/context that does not compile as a Unicode regex.
 */
export function parseLanguagePack(json: string): LanguagePack {
  let decoded: unknown;
  try {
    decoded = JSON.parse(json);
  } catch (e) {
    throw new PackError('', `invalid JSON: ${(e as Error).message}`);
  }
  if (!isMap(decoded)) {
    throw new PackError('', 'pack must be a JSON object');
  }
  return languagePackFromJson(decoded);
}

/** Dart `LanguagePack.fromJson`: fields are read in the Dart order, so the first error is the same. */
export function languagePackFromJson(json: JsonMap): LanguagePack {
  const scriptName = str(json, 'script', '');
  if (!(scripts as readonly string[]).includes(scriptName)) {
    throw new PackError('script', `unknown script "${scriptName}"`);
  }
  const conf = opt(json, 'minConfidence', '', 'num');
  return {
    code: str(json, 'code', ''),
    appleLocale: str(json, 'appleLocale', ''),
    androidLocale: str(json, 'androidLocale', ''),
    whisperCode: str(json, 'whisperCode', ''),
    label: str(json, 'label', ''),
    labelLatin: str(json, 'labelLatin', ''),
    script: scriptName as Script,
    minConfidence: conf ?? null,
    recognition: objList(json, 'recognition', ruleFromJson),
    beforeTranslation: objList(json, 'beforeTranslation', ruleFromJson),
    terms: objList(json, 'terms', termFromJson),
    hints: strList(json, 'hints', ''),
  };
}

/** Dart `Rule.fromJson`; `path` is e.g. `recognition[0]`. */
export function ruleFromJson(json: JsonMap, path: string): Rule {
  const id = str(json, 'id', path);
  const pattern = str(json, 'pattern', path);
  const template = str(json, 'template', path);
  const atClauseStart = opt(json, 'atClauseStart', path, 'bool') ?? false;
  const context = opt(json, 'context', path, 'String');
  checkRegex(pattern, `${path}.pattern`);
  if (context !== undefined) {
    checkRegex(context, `${path}.context`);
  }
  const rule: Rule = {id, pattern, template, atClauseStart};
  return context === undefined ? rule : {...rule, context};
}

/** Dart `Term.fromJson`; `path` is e.g. `terms[0]`. */
export function termFromJson(json: JsonMap, path: string): Term {
  const originName = opt(json, 'origin', path, 'String');
  let origin: TermOrigin;
  if (originName === undefined) {
    origin = 'user';
  } else if ((termOrigins as readonly string[]).includes(originName)) {
    origin = originName as TermOrigin;
  } else {
    throw new PackError(`${path}.origin`, `unknown origin "${originName}"`);
  }
  const fixedJson = opt(json, 'fixed', path, 'Map<dynamic, dynamic>') ?? {};
  const id = str(json, 'id', path);
  const text = str(json, 'text', path);
  const variants = strList(json, 'variants', path);
  const fixed: Record<string, string> = {};
  for (const [k, v] of Object.entries(fixedJson)) {
    if (typeof v !== 'string') {
      throw new PackError(`${path}.fixed`, 'values must be strings');
    }
    fixed[k] = v;
  }
  return {id, text, variants, fixed, origin};
}

// --- JSON helpers (Dart `_str`, `_opt<T>`, `_strList`, `_objList`) ----------

const join = (path: string, key: string): string => (path === '' ? key : `${path}.${key}`);

function str(json: JsonMap, key: string, path: string): string {
  const v = json[key];
  if (v === undefined || v === null) {
    throw new PackError(join(path, key), 'missing');
  }
  if (typeof v !== 'string') {
    throw new PackError(join(path, key), 'must be a string');
  }
  return v;
}

/** The Dart type names `_opt<T>` prints in its reason, and their JS checks. */
interface OptTypes {
  bool: boolean;
  String: string;
  num: number;
  'Map<dynamic, dynamic>': JsonMap;
  'List<dynamic>': unknown[];
}

const optChecks: {[K in keyof OptTypes]: (v: unknown) => boolean} = {
  bool: v => typeof v === 'boolean',
  String: v => typeof v === 'string',
  num: v => typeof v === 'number',
  'Map<dynamic, dynamic>': isMap,
  'List<dynamic>': Array.isArray,
};

/** Absent or null → undefined; a value of another type → "must be a <Dart type>". */
function opt<K extends keyof OptTypes>(
  json: JsonMap,
  key: string,
  path: string,
  type: K,
): OptTypes[K] | undefined {
  const v = json[key];
  if (v === undefined || v === null) {
    return undefined;
  }
  if (!optChecks[type](v)) {
    throw new PackError(join(path, key), `must be a ${type}`);
  }
  return v as OptTypes[K];
}

function strList(json: JsonMap, key: string, path: string): string[] {
  const v = opt(json, key, path, 'List<dynamic>');
  if (v === undefined) {
    return [];
  }
  return v.map(e => {
    if (typeof e !== 'string') {
      throw new PackError(join(path, key), 'entries must be strings');
    }
    return e;
  });
}

/** Top-level lists of objects only (Dart reads them with an empty path). */
function objList<T>(
  json: JsonMap,
  key: string,
  parse: (entry: JsonMap, path: string) => T,
): T[] {
  const v = opt(json, key, '', 'List<dynamic>');
  if (v === undefined) {
    return [];
  }
  return v.map((e, i) => {
    if (!isMap(e)) {
      throw new PackError(`${key}[${i}]`, 'must be an object');
    }
    return parse(e, `${key}[${i}]`);
  });
}

function checkRegex(pattern: string, field: string): void {
  try {
    RegExp(pattern, 'u');
  } catch (e) {
    throw new PackError(field, `invalid regex: ${regexMessage((e as Error).message)}`);
  }
}

/** V8 says "Invalid regular expression: /(/u: Unterminated group"; Dart keeps the last part. */
function regexMessage(message: string): string {
  const m = /^Invalid regular expression: \/.*\/[a-z]*: (.*)$/s.exec(message);
  return m ? m[1] : message;
}
