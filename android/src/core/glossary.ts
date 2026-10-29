// Port of app/lib/core/glossary.dart. Contract: shared/fixtures/glossary.json
// (shared/fixtures/README.md, "glossary.json — glossary validation"). The Dart store keeps a file;
// here the JSON list lives under one key of a `KeyValueStore` (AsyncStorage in the app, memory in
// tests), on the phone only (R17).
import {graphemes} from '../board/protocol';
import {TypedEmitter, type Unsubscribe} from '../engine/VoiceEngine';
import {termFromJson, type Term} from './model';

// --- errors ------------------------------------------------------------------------------

/** Why a glossary change was refused or failed. `name` is the fixture's error name. */
export abstract class GlossaryError extends Error {
  protected constructor(name: string, message: string) {
    super(message);
    this.name = name;
  }
}

/** A term, variant or fixed translation is empty or only blanks. */
export class EmptyText extends GlossaryError {
  constructor(readonly field: string) {
    super('EmptyText', `EmptyText(${field})`);
  }
}

/** A string is longer than `limit` characters (grapheme clusters, Dart `characters.length`). */
export class TooLong extends GlossaryError {
  constructor(readonly field: string, readonly limit: number) {
    super('TooLong', `TooLong(${field} > ${limit})`);
  }
}

/** A term has more than `limit` variants. */
export class TooManyVariants extends GlossaryError {
  constructor(readonly limit: number) {
    super('TooManyVariants', `TooManyVariants(> ${limit})`);
  }
}

/** The glossary already holds `limit` terms. */
export class TooManyTerms extends GlossaryError {
  constructor(readonly limit: number) {
    super('TooManyTerms', `TooManyTerms(> ${limit})`);
  }
}

/** A string holds a control character or a bidirectional override. */
export class ForbiddenCharacter extends GlossaryError {
  constructor(readonly field: string, readonly codePoint: number) {
    super(
      'ForbiddenCharacter',
      `ForbiddenCharacter(${field}, U+${codePoint.toString(16).toUpperCase().padStart(4, '0')})`,
    );
  }
}

/** `value` is already a term or variant (ignoring case) of another entry. */
export class DuplicateTerm extends GlossaryError {
  constructor(readonly field: string, readonly value: string) {
    super('DuplicateTerm', `DuplicateTerm(${field}: ${value})`);
  }
}

/** No term has this id. */
export class UnknownTerm extends GlossaryError {
  constructor(readonly id: string) {
    super('UnknownTerm', `UnknownTerm(${id})`);
  }
}

/** The glossary could not be written; nothing was changed. */
export class GlossaryWriteError extends GlossaryError {
  constructor(readonly cause: unknown) {
    super('GlossaryWriteError', `GlossaryWriteError(${String(cause)})`);
  }
}

// --- storage -----------------------------------------------------------------------------

/** The part of AsyncStorage the glossary needs (AsyncStorage satisfies it as is). */
export interface KeyValueStore {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

/** A `KeyValueStore` in memory, for tests; `failWrites` makes setItem/removeItem reject. */
export class MemoryKeyValueStore implements KeyValueStore {
  readonly items = new Map<string, string>();
  failWrites = false;

  async getItem(key: string): Promise<string | null> {
    return this.items.get(key) ?? null;
  }

  async setItem(key: string, value: string): Promise<void> {
    if (this.failWrites) {
      throw new Error('write failed');
    }
    this.items.set(key, value);
  }

  async removeItem(key: string): Promise<void> {
    if (this.failWrites) {
      throw new Error('write failed');
    }
    this.items.delete(key);
  }
}

/** The app's AsyncStorage (the default, shared database). */
export function asyncStorageKeyValueStore(): KeyValueStore {
  // Required on first use, not at import: the module binds the native TurboModule.
  const mod = require('@react-native-async-storage/async-storage') as {default: KeyValueStore};
  return mod.default;
}

// --- the store ---------------------------------------------------------------------------

export interface GlossaryEvents {
  /** The new list after every successful change. */
  changed: readonly Term[];
}

export interface TermInput {
  readonly text: string;
  readonly variants?: readonly string[];
  readonly fixed?: Readonly<Record<string, string>>;
}

export interface GlossaryOpenOptions {
  /** The key the JSON list is stored under (default `glossary`). */
  readonly key?: string;
  /** Local time for the corrupt-data key (tests). */
  readonly clock?: () => Date;
  /** Id of a new term (tests); default 16 random hex digits. */
  readonly newId?: () => string;
}

/** A value the stored glossary cannot be read back from. */
class CorruptData extends Error {}

/**
 * The user's glossary (R11): a JSON list of `Term` (pack term format) under one key, on the phone
 * only. Limits: 500 terms, 64 characters (grapheme clusters) per term, variant and fixed
 * translation, 8 variants; control characters and bidirectional overrides (U+202A-U+202E, U+2066-U+2069) are
 * rejected, and every term or variant is unique ignoring case.
 *
 * Stored data that cannot be read back is moved to `<key>.corrupt-<yyyyMMdd-HHmmss>` and the store
 * starts empty (`recoveredFromCorruption`); it never throws for bad data.
 */
export class GlossaryStore {
  static readonly maxTerms = 500;
  static readonly maxLength = 64;
  static readonly maxVariants = 8;

  /** Fires `changed` after every successful change. */
  readonly changes = new TypedEmitter<GlossaryEvents>();

  private termList: readonly Term[] = Object.freeze([]);
  private recovered = false;
  private queue: Promise<unknown> = Promise.resolve();

  private constructor(
    private readonly kv: KeyValueStore,
    private readonly key: string,
    private readonly clock: () => Date,
    private readonly newId: () => string,
  ) {}

  /** Reads the stored glossary (there need not be one yet). A storage read error propagates. */
  static async open(kv: KeyValueStore, options: GlossaryOpenOptions = {}): Promise<GlossaryStore> {
    const store = new GlossaryStore(
      kv,
      options.key ?? 'glossary',
      options.clock ?? (() => new Date()),
      options.newId ?? randomId,
    );
    await store.load();
    return store;
  }

  /** The terms, in the order they were added (frozen). */
  get terms(): readonly Term[] {
    return this.termList;
  }

  /** True when the stored data was unreadable at `open` and has been set aside. */
  get recoveredFromCorruption(): boolean {
    return this.recovered;
  }

  /** Subscribes to changes; same as `changes.on('changed', handler)`. */
  onChange(handler: (terms: readonly Term[]) => void): Unsubscribe {
    return this.changes.on('changed', handler);
  }

  /** Adds a term (always origin user) and returns it with its id. */
  add(input: TermInput): Promise<Term> {
    return this.serial(async () => {
      if (this.termList.length >= GlossaryStore.maxTerms) {
        throw new TooManyTerms(GlossaryStore.maxTerms);
      }
      const term = this.validated(this.newId(), input, null);
      await this.commit([...this.termList, term]);
      return term;
    });
  }

  /** Replaces the term `id`. */
  update(id: string, input: TermInput): Promise<Term> {
    return this.serial(async () => {
      const index = this.termList.findIndex(t => t.id === id);
      if (index < 0) {
        throw new UnknownTerm(id);
      }
      const term = this.validated(id, input, id);
      const next = [...this.termList];
      next[index] = term;
      await this.commit(next);
      return term;
    });
  }

  /** Deletes the term `id`. */
  remove(id: string): Promise<void> {
    return this.serial(async () => {
      if (!this.termList.some(t => t.id === id)) {
        throw new UnknownTerm(id);
      }
      await this.commit(this.termList.filter(t => t.id !== id));
    });
  }

  /** Drops every change listener. */
  dispose(): void {
    this.changes.removeAll();
  }

  // --- internals -------------------------------------------------------------------------

  /** Changes run one after the other, so two quick edits never interleave their writes. */
  private serial<T>(action: () => Promise<T>): Promise<T> {
    const result = this.queue.then(action);
    this.queue = result.catch(() => undefined);
    return result;
  }

  private validated(id: string, input: TermInput, ignoring: string | null): Term {
    const variants = input.variants ?? [];
    const cleanText = check('text', input.text);
    if (variants.length > GlossaryStore.maxVariants) {
      throw new TooManyVariants(GlossaryStore.maxVariants);
    }
    const cleanVariants = variants.map((v, i) => check(`variants[${i}]`, v));
    const cleanFixed: Record<string, string> = {};
    for (const [rawCode, value] of Object.entries(input.fixed ?? {})) {
      const code = dartTrim(rawCode);
      if (code === '') {
        throw new EmptyText('fixed');
      }
      cleanFixed[code] = check(`fixed.${code}`, value);
    }

    const taken = new Set<string>();
    for (const t of this.termList) {
      if (t.id !== ignoring) {
        for (const s of [t.text, ...t.variants]) {
          taken.add(keyOf(s));
        }
      }
    }
    const surfaces = [cleanText, ...cleanVariants];
    surfaces.forEach((s, i) => {
      const k = keyOf(s);
      if (taken.has(k)) {
        throw new DuplicateTerm(i === 0 ? 'text' : `variants[${i - 1}]`, s);
      }
      taken.add(k);
    });
    return {id, text: cleanText, variants: cleanVariants, fixed: cleanFixed, origin: 'user'};
  }

  private async commit(next: Term[]): Promise<void> {
    try {
      await this.kv.setItem(this.key, JSON.stringify(next));
    } catch (e) {
      throw new GlossaryWriteError(e);
    }
    this.termList = Object.freeze(next);
    try {
      this.changes.emit('changed', this.termList);
    } catch (e) {
      // A listener's bug must not turn a saved change into a failed one.
      console.error('glossary change listener failed', e);
    }
  }

  private async load(): Promise<void> {
    const raw = await this.kv.getItem(this.key);
    if (raw === null) {
      return;
    }
    try {
      this.termList = Object.freeze(parseStored(raw));
    } catch {
      await this.setAside(raw);
    }
  }

  private async setAside(raw: string): Promise<void> {
    const now = this.clock();
    const two = (n: number) => String(n).padStart(2, '0');
    const stamp =
      `${String(now.getFullYear()).padStart(4, '0')}${two(now.getMonth() + 1)}${two(now.getDate())}` +
      `-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`;
    const base = `${this.key}.corrupt-${stamp}`;
    try {
      let target = base;
      for (let n = 1; (await this.kv.getItem(target)) !== null; n++) {
        target = `${base}-${n}`;
      }
      await this.kv.setItem(target, raw);
      await this.kv.removeItem(this.key);
    } catch (e) {
      // Storage failed part-way. If the copy was not written, the bad value stays under `key`
      // with no copy. If the copy was written but `removeItem` failed, both exist: the next
      // change overwrites `key`, and until then every `open` sets the value aside again under
      // the next free `-n` key (one more copy each time). Either way this store starts empty,
      // which beats not starting.
      console.warn('glossary: could not set corrupt data aside', e);
    }
    this.termList = Object.freeze([]);
    this.recovered = true;
  }
}

/** The stored JSON list, validated with the same limits as typing. Throws for anything bad. */
function parseStored(raw: string): Term[] {
  const decoded: unknown = JSON.parse(raw);
  if (!Array.isArray(decoded)) {
    throw new CorruptData('not a list');
  }
  const loaded = decoded.map((entry: unknown, i) => {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
      throw new CorruptData(`entry ${i} is not an object`);
    }
    return termFromJson(entry as {[key: string]: unknown}, `[${i}]`);
  });
  // A hand-edited value must not get around the limits.
  if (loaded.length > GlossaryStore.maxTerms) {
    throw new CorruptData('too many terms');
  }
  const seen = new Set<string>();
  for (const t of loaded) {
    check('text', t.text);
    if (t.variants.length > GlossaryStore.maxVariants) {
      throw new CorruptData('variants');
    }
    t.variants.forEach(v => check('variants', v));
    Object.values(t.fixed).forEach(v => check('fixed', v));
    for (const s of [t.text, ...t.variants]) {
      const k = keyOf(s);
      if (seen.has(k)) {
        throw new CorruptData(`duplicate ${s}`);
      }
      seen.add(k);
    }
  }
  return loaded;
}

const keyOf = (s: string): string => s.normalize('NFC').toLowerCase();

/** Dart `String.trim`: JS whitespace plus U+0085. */
const dartTrim = (s: string): string => s.replace(/^[\s\u0085]+|[\s\u0085]+$/g, '');

/** Trims `value` and applies the per-string rules. */
function check(field: string, value: string): string {
  const s = dartTrim(value);
  if (s === '') {
    throw new EmptyText(field);
  }
  for (const c of s) {
    const cp = c.codePointAt(0)!;
    if (
      cp <= 0x1f ||
      (cp >= 0x7f && cp <= 0x9f) ||
      (cp >= 0x202a && cp <= 0x202e) ||
      (cp >= 0x2066 && cp <= 0x2069)
    ) {
      throw new ForbiddenCharacter(field, cp);
    }
  }
  if (graphemes(s).length > GlossaryStore.maxLength) {
    throw new TooLong(field, GlossaryStore.maxLength);
  }
  return s;
}

function randomId(): string {
  let id = '';
  for (let i = 0; i < 8; i++) {
    id += Math.floor(Math.random() * 256)
      .toString(16)
      .padStart(2, '0');
  }
  return id;
}
