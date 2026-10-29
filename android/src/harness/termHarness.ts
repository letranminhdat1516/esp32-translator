// Term harness (P2.5, R10): corpus, scoring, report and pack update, all pure. Driven on the Mac by
// scripts/term-harness.mjs (ML Kit answers come from the phone, see tool/term_harness.sh); the Swift
// twin is ios/Tools/term-harness. Both pass shared/fixtures/terms/harness.json; format and scoring
// rule: shared/fixtures/terms/README.md.
import type {Term} from '../core/model';
import {TermProtector} from '../core/termProtector';

/** Placeholder shapes tried, in tie-break order. */
export const SHAPES = ['Zorvik{n}', '[[{n}]]', 'TERM{n}', '⟦{n}⟧', '__{n}__'] as const;

/** The R10 target in tenths of a percent. */
const TARGET_TENTHS = 950;

/** One corpus sentence: translate `source` from `from` to `to`; `expected` must be in the output. */
export interface CorpusLine {
  /** The file's language (the pair is this language and vi). */
  readonly lang: string;
  readonly from: string;
  readonly to: string;
  readonly source: string;
  readonly term: string;
  /** The term verbatim, or its fixed translation for `to`. */
  readonly expected: string;
  /** 1-based line number in the file. */
  readonly lineNo: number;
}

export type CorpusErrorKind = 'columns' | 'direction' | 'empty';

/** A corpus line that is not `direction<TAB>source<TAB>term<TAB>expected`. */
export class CorpusError extends Error {
  constructor(readonly kind: CorpusErrorKind, readonly lineNo: number, detail: string) {
    super(`line ${lineNo}: ${detail}`);
    this.name = 'CorpusError';
  }
}

/** The term of a line is not found (masked) in its source sentence. */
export class TermNotFoundError extends Error {
  constructor(readonly line: CorpusLine) {
    super(`line ${line.lineNo}: term "${line.term}" is not masked in "${line.source}"`);
    this.name = 'TermNotFoundError';
  }
}

/**
 * Parses a corpus file of language `lang`. Blank lines and lines starting with `#` are skipped; a
 * trailing CR is dropped. Throws `CorpusError`.
 */
export function parseCorpus(text: string, lang: string): CorpusLine[] {
  const out: CorpusLine[] = [];
  text.split('\n').forEach((raw, i) => {
    const lineNo = i + 1;
    const row = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (row.trim() === '' || row.startsWith('#')) {
      return;
    }
    const cols = row.split('\t');
    if (cols.length !== 4) {
      throw new CorpusError('columns', lineNo, `${cols.length} columns, expected 4`);
    }
    const [direction, source, term, expected] = cols;
    const pair = direction.split('>');
    const ok =
      pair.length === 2 &&
      ((pair[0] === lang && pair[1] === 'vi') || (pair[0] === 'vi' && pair[1] === lang));
    if (!ok) {
      throw new CorpusError('direction', lineNo, `direction "${direction}" is not ${lang}>vi or vi>${lang}`);
    }
    if (source === '' || term === '' || expected === '') {
      throw new CorpusError('empty', lineNo, 'empty field');
    }
    out.push({lang, from: pair[0], to: pair[1], source, term, expected, lineNo});
  });
  return out;
}

/** The protected term of a line: the term, with `expected` as its fixed translation when it differs. */
export function termOf(line: CorpusLine): Term {
  return {
    id: line.term,
    text: line.term,
    variants: [],
    fixed: line.expected === line.term ? {} : {[line.to]: line.expected},
    origin: 'user',
  };
}

/** True when `output` holds `expected` (both NFC, exact case, anywhere). */
export function passes(output: string, expected: string): boolean {
  return output.normalize('NFC').includes(expected.normalize('NFC'));
}

export interface Outcome {
  /** The text sent to the translator first. */
  readonly masked: string;
  /** The placeholders survived (no fallback). */
  readonly restored: boolean;
  /** What the app would show. */
  readonly output: string;
  readonly passed: boolean;
}

const protector = new TermProtector();

/**
 * Runs one line through the app's term path with `shape`: mask, translate, restore; when a
 * placeholder is lost, translate the plain source and repair fixed terms (TextPipeline.repair).
 * Throws `TermNotFoundError` when the term is not masked.
 */
export async function evaluate(
  line: CorpusLine,
  shape: string,
  translate: (text: string) => Promise<string>,
): Promise<Outcome> {
  const m = protector.mask(line.source, [termOf(line)], line.to, shape);
  if (m.isEmpty) {
    throw new TermNotFoundError(line);
  }
  const restored = protector.restore(await translate(m.text), m);
  if (restored !== null) {
    return {masked: m.text, restored: true, output: restored, passed: passes(restored, line.expected)};
  }
  let output = await translate(line.source);
  for (const [surface, replacement] of m.replacements) {
    if (surface !== replacement) {
      output = output.replace(TermProtector.wholeWordRegex(surface, true), () => replacement);
    }
  }
  return {masked: m.text, restored: false, output, passed: passes(output, line.expected)};
}

/**
 * The scripted fake translator: returns the text with `[[`/`]]` and `__` halved, so the bracket
 * and underscore shapes lose their placeholders and the others keep them.
 */
export function scripted(text: string): string {
  return text.split('[[').join('[').split(']]').join(']').split('__').join('_');
}

/** Translates `text` from `from` to `to` (catalog codes). */
export type Translate = (text: string, from: string, to: string) => Promise<string>;

/**
 * Every line with every shape. A translator error fails that line × shape (not restored, not
 * passed) and is listed in `errors`; a term that is not masked throws `TermNotFoundError`.
 */
export async function runCorpus(
  lines: readonly CorpusLine[],
  shapes: readonly string[],
  translate: Translate,
): Promise<{results: Result[]; errors: string[]}> {
  const results: Result[] = [];
  const errors: string[] = [];
  for (const line of lines) {
    for (const shape of shapes) {
      const base = {lang: line.lang, from: line.from, to: line.to, shape};
      try {
        const o = await evaluate(line, shape, text => translate(text, line.from, line.to));
        results.push({...base, restored: o.restored, passed: o.passed});
      } catch (e) {
        if (e instanceof TermNotFoundError) {
          throw e;
        }
        errors.push(`${line.lang}:${line.lineNo} ${shape}: ${(e as Error).message}`);
        results.push({...base, restored: false, passed: false});
      }
    }
  }
  return {results, errors};
}

/** One TSV field: backslash, tab, LF and CR written as `\\`, `\t`, `\n`, `\r`. */
export function escapeField(s: string): string {
  return s.replace(/[\\\t\n\r]/g, c => ({'\\': '\\\\', '\t': '\\t', '\n': '\\n', '\r': '\\r'})[c]!);
}

/** Inverse of `escapeField`. */
export function unescapeField(s: string): string {
  return s.replace(/\\([\\tnr])/g, (_, c: string) => ({'\\': '\\', t: '\t', n: '\n', r: '\r'})[c]!);
}

/** One line × one shape. */
export interface Result {
  readonly lang: string;
  readonly from: string;
  readonly to: string;
  readonly shape: string;
  readonly restored: boolean;
  readonly passed: boolean;
}

export interface Best {
  readonly shape: string;
  readonly passed: number;
  readonly total: number;
  readonly lost: number;
}

interface Tally {
  passed: number;
  total: number;
  lost: number;
}

function tally(results: readonly Result[]): Tally {
  return {
    passed: results.filter(r => r.passed).length,
    total: results.length,
    lost: results.filter(r => !r.restored).length,
  };
}

function languages(results: readonly Result[]): string[] {
  return [...new Set(results.map(r => r.lang))];
}

/**
 * Best shape per language (in order of first appearance): most passes over both directions, then
 * fewest lost placeholders, then the earlier shape in `shapes`.
 */
export function bestShapes(results: readonly Result[], shapes: readonly string[]): Map<string, Best> {
  const best = new Map<string, Best>();
  for (const lang of languages(results)) {
    let top: Best | undefined;
    for (const shape of shapes) {
      const t = tally(results.filter(r => r.lang === lang && r.shape === shape));
      if (t.total === 0) {
        continue;
      }
      if (top === undefined || t.passed > top.passed || (t.passed === top.passed && t.lost < top.lost)) {
        top = {shape, ...t};
      }
    }
    if (top !== undefined) {
      best.set(lang, top);
    }
  }
  return best;
}

/** passed/total in tenths of a percent, rounded half up. */
function tenths(passed: number, total: number): number {
  return Math.floor((passed * 2000 + total) / (2 * total));
}

function percent(t: number): string {
  return `${Math.floor(t / 10)}.${t % 10} %`;
}

/** The Markdown report: one row per language and direction (plus both), one column per shape; then the best shapes. */
export function report(results: readonly Result[], shapes: readonly string[], engine: string): string {
  const rows: string[] = [
    `## Term accuracy: ${engine}`,
    '',
    `| Language | Direction | ${shapes.map(s => `\`${s}\``).join(' | ')} |`,
    `|---|---|${shapes.map(() => '---:|').join('')}`,
  ];
  for (const lang of languages(results)) {
    const of = results.filter(r => r.lang === lang);
    const groups: [string, Result[]][] = [
      [`${lang} → vi`, of.filter(r => r.to === 'vi')],
      [`vi → ${lang}`, of.filter(r => r.from === 'vi')],
      ['both', of],
    ];
    for (const [label, group] of groups) {
      const count = Math.max(...shapes.map(s => group.filter(r => r.shape === s).length));
      const cells = shapes.map(s => {
        const t = tally(group.filter(r => r.shape === s));
        return t.total === 0 ? '—' : `${percent(tenths(t.passed, t.total))} · ${t.lost} lost`;
      });
      rows.push(`| ${lang} | ${label} (${count}) | ${cells.join(' | ')} |`);
    }
  }
  rows.push(
    '',
    '| Language | Best shape | Accuracy | Lost placeholders | R10 (≥ 95 %) |',
    '|---|---|---:|---:|---|',
  );
  for (const [lang, b] of bestShapes(results, shapes)) {
    const t = tenths(b.passed, b.total);
    const verdict = t >= TARGET_TENTHS ? 'yes' : `no (${percent(TARGET_TENTHS - t).slice(0, -2)} points short)`;
    rows.push(`| ${lang} | \`${b.shape}\` | ${percent(t)} | ${b.lost} | ${verdict} |`);
  }
  return rows.join('\n') + '\n';
}

/**
 * Sets the top-level string `key` of a pack file to `shape`, keeping the rest of the text as is:
 * replaces the value of an existing `"key": ...` line, or inserts the line after `"whisperCode"`.
 */
export function setPlaceholder(packText: string, key: string, shape: string): string {
  if (/["\\\n]/.test(shape)) {
    throw new Error(`placeholder ${JSON.stringify(shape)} cannot be written`);
  }
  const lines = packText.split('\n');
  const existing = lines.findIndex(l => l.trimStart().startsWith(`"${key}":`));
  if (existing >= 0) {
    const l = lines[existing];
    const indent = l.slice(0, l.length - l.trimStart().length);
    lines[existing] = `${indent}"${key}": "${shape}"${l.trimEnd().endsWith(',') ? ',' : ''}`;
    return lines.join('\n');
  }
  const anchor = lines.findIndex(l => l.trimStart().startsWith('"whisperCode":'));
  if (anchor < 0) {
    throw new Error('no "whisperCode" line to insert the placeholder after');
  }
  const a = lines[anchor];
  const indent = a.slice(0, a.length - a.trimStart().length);
  lines.splice(anchor + 1, 0, `${indent}"${key}": "${shape}",`);
  return lines.join('\n');
}
