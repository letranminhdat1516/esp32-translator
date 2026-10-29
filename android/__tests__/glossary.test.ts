// Port of app/test/core/glossary_test.dart. Cases: shared/fixtures/glossary.json
// (shared/fixtures/README.md, "glossary.json — glossary validation"); storage is a KeyValueStore
// (AsyncStorage in the app, in memory here) instead of a file.
import {
  asyncStorageKeyValueStore,
  DuplicateTerm,
  EmptyText,
  ForbiddenCharacter,
  GlossaryError,
  GlossaryStore,
  GlossaryWriteError,
  MemoryKeyValueStore,
  TooLong,
  TooManyTerms,
  TooManyVariants,
  UnknownTerm,
} from '../src/core/glossary';
import type {Term} from '../src/core/model';
import {casesOf, loadFixture, type JsonObject} from './fixtures';

// The package's own jest mock is untranspiled ESM (outside transformIgnorePatterns), so an
// equivalent in-memory default export stands in for the native module.
jest.mock('@react-native-async-storage/async-storage', () => {
  const items = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: async (k: string) => items.get(k) ?? null,
      setItem: async (k: string, v: string) => {
        items.set(k, v);
      },
      removeItem: async (k: string) => {
        items.delete(k);
      },
    },
  };
});

const KEY = 'glossary';
const ASIDE = 'glossary.corrupt-20260304-050607';

let kv: MemoryKeyValueStore;
let idCounter = 0;
const clock = () => new Date(2026, 2, 4, 5, 6, 7);

function open(store: MemoryKeyValueStore = kv): Promise<GlossaryStore> {
  return GlossaryStore.open(store, {clock, newId: () => `id${++idCounter}`});
}

beforeEach(() => {
  kv = new MemoryKeyValueStore();
  idCounter = 0;
});

const texts = (store: GlossaryStore) => store.terms.map(t => t.text);

describe('basic use', () => {
  test('starts empty without stored data', async () => {
    const store = await open();
    expect(store.terms).toEqual([]);
    expect(store.recoveredFromCorruption).toBe(false);
    expect(kv.items.has(KEY)).toBe(false);
  });

  test('add stores a user term and survives a relaunch', async () => {
    const store = await open();
    const t = await store.add({text: '  Bến Thành ', variants: ['Ben Thanh'], fixed: {en: 'Ben Thanh Market'}});
    expect(t).toEqual({
      id: 'id1',
      text: 'Bến Thành',
      variants: ['Ben Thanh'],
      fixed: {en: 'Ben Thanh Market'},
      origin: 'user',
    });
    expect(store.terms).toEqual([t]);
    expect((await open()).terms).toEqual([t]);
    // The stored value is a JSON list of terms in the pack term format.
    expect(JSON.parse(kv.items.get(KEY)!)[0].text).toBe('Bến Thành');
  });

  test('update replaces a term by id, remove deletes it', async () => {
    const store = await open();
    const a = await store.add({text: 'Zalo'});
    const b = await store.add({text: 'Grab'});
    const changed = await store.update(a.id, {text: 'Zalo Pay', fixed: {en: 'ZaloPay'}});
    expect(changed.id).toBe(a.id);
    expect(texts(store)).toEqual(['Zalo Pay', 'Grab']);
    await store.remove(b.id);
    expect(texts(store)).toEqual(['Zalo Pay']);
    expect((await open()).terms[0].fixed).toEqual({en: 'ZaloPay'});
  });

  test('update or remove of an unknown id is an error', async () => {
    const store = await open();
    await expect(store.update('nope', {text: 'x'})).rejects.toBeInstanceOf(UnknownTerm);
    await expect(store.remove('nope')).rejects.toBeInstanceOf(UnknownTerm);
  });

  test('terms is read-only', async () => {
    const store = await open();
    await store.add({text: 'A'});
    expect(Object.isFrozen(store.terms)).toBe(true);
    expect(() => (store.terms as Term[]).push(store.terms[0])).toThrow(TypeError);
  });

  test('ids are random hex by default', async () => {
    const store = await GlossaryStore.open(kv);
    const a = await store.add({text: 'A'});
    const b = await store.add({text: 'B'});
    expect(a.id).toMatch(/^[0-9a-f]{16}$/);
    expect(b.id).not.toBe(a.id);
  });
});

describe('change events', () => {
  test('fire on add, update and remove, to several listeners', async () => {
    const store = await open();
    const one: string[][] = [];
    const two: string[][] = [];
    store.changes.on('changed', l => one.push(l.map(t => t.text)));
    store.changes.on('changed', l => two.push(l.map(t => t.text)));
    const a = await store.add({text: 'A'});
    await store.update(a.id, {text: 'B'});
    await store.remove(a.id);
    expect(one).toEqual([['A'], ['B'], []]);
    expect(two).toEqual(one);
  });

  test('do not fire for a rejected change', async () => {
    const store = await open();
    const fired = jest.fn();
    store.changes.on('changed', fired);
    await expect(store.add({text: ''})).rejects.toBeInstanceOf(EmptyText);
    expect(fired).not.toHaveBeenCalled();
  });

  test('a listener that throws does not undo or fail the change', async () => {
    const store = await open();
    const error = jest.spyOn(console, 'error').mockImplementation(() => {});
    try {
      store.changes.on('changed', () => {
        throw new Error('listener');
      });
      await expect(store.add({text: 'A'})).resolves.toEqual(expect.objectContaining({text: 'A'}));
      expect(texts(store)).toEqual(['A']);
      expect(error).toHaveBeenCalled();
    } finally {
      error.mockRestore();
    }
  });

  test('dispose removes the listeners', async () => {
    const store = await open();
    const fired = jest.fn();
    store.changes.on('changed', fired);
    store.dispose();
    await store.add({text: 'A'});
    expect(fired).not.toHaveBeenCalled();
  });
});

describe('glossary.json cases', () => {
  const fixture = loadFixture('glossary');
  const limits = fixture.limits as JsonObject;

  test('limits', () => {
    expect(GlossaryStore.maxTerms).toBe(limits.maxTerms);
    expect(GlossaryStore.maxLength).toBe(limits.maxLength);
    expect(GlossaryStore.maxVariants).toBe(limits.maxVariants);
  });

  function expectError(e: unknown, want: JsonObject): void {
    expect(e).toBeInstanceOf(GlossaryError);
    const err = e as GlossaryError;
    expect(err.name).toBe(want.error);
    if (err instanceof EmptyText) {
      expect(err.field).toBe(want.field);
    } else if (err instanceof TooLong) {
      expect([err.field, err.limit]).toEqual([want.field, want.limit]);
    } else if (err instanceof TooManyVariants || err instanceof TooManyTerms) {
      expect(err.limit).toBe(want.limit);
    } else if (err instanceof ForbiddenCharacter) {
      expect([err.field, err.codePoint]).toEqual([want.field, want.codePoint]);
    } else if (err instanceof DuplicateTerm) {
      expect([err.field, err.value]).toEqual([want.field, want.value]);
    }
  }

  const inputOf = (j: JsonObject | undefined) => ({
    text: j!.text as string,
    variants: (j!.variants as string[] | undefined) ?? [],
    fixed: (j!.fixed as Record<string, string> | undefined) ?? {},
  });

  test.each(casesOf(fixture, 'cases').map(c => [c.name as string, c] as const))('%s', async (_, c) => {
    const store = await open();
    const existing: Term[] = [];
    for (const e of casesOf(c, 'existing')) {
      existing.push(await store.add(inputOf(e)));
    }
    const input = c.input as JsonObject | undefined;
    const target =
      (c.targetId as string | undefined) ??
      (c.target === undefined ? undefined : existing[c.target as number].id);
    const before = kv.items.get(KEY) ?? null;
    const want = c.expect as JsonObject;
    const run = async (): Promise<Term | null> => {
      switch (c.op) {
        case 'add':
          return store.add(inputOf(input));
        case 'update':
          return store.update(target!, inputOf(input));
        case 'remove':
          await store.remove(target!);
          return null;
        default:
          throw new Error(`unknown op ${String(c.op)}`);
      }
    };
    if (want.ok === true) {
      const t = await run();
      if ('text' in want) {
        expect(t!.text).toBe(want.text);
      }
      if ('variants' in want) {
        expect(t!.variants).toEqual(want.variants);
      }
      if ('fixed' in want) {
        expect(t!.fixed).toEqual(want.fixed);
      }
      if ('allTexts' in want) {
        expect(texts(store)).toEqual(want.allTexts);
      }
      if (t !== null) {
        expect(t.origin).toBe('user');
      }
    } else {
      let caught: unknown = null;
      try {
        await run();
      } catch (e) {
        caught = e;
      }
      expect(caught).not.toBeNull();
      expectError(caught, want);
      // A rejected change leaves the list and the stored data untouched.
      expect(store.terms).toEqual(existing);
      expect(kv.items.get(KEY) ?? null).toBe(before);
    }
  });

  describe('load', () => {
    test.each(casesOf(fixture, 'load').map(c => [c.name as string, c] as const))('%s', async (_, c) => {
      const content = c.content as string;
      kv.items.set(KEY, content);
      const store = await open();
      expect(texts(store)).toEqual((c.texts as string[] | undefined) ?? []);
      expect(store.recoveredFromCorruption).toBe(c.recovered);
      if (c.recovered === true) {
        // Platform-specific: the bad value is moved aside under a time-stamped key.
        expect(kv.items.has(KEY)).toBe(false);
        expect(kv.items.get(ASIDE)).toBe(content);
        // and the store works again
        await store.add({text: 'A'});
        expect(texts(await open())).toEqual(['A']);
        expect((await open()).recoveredFromCorruption).toBe(false);
      }
    });
  });
});

describe('rejections and storage failures, not fixture-driven', () => {
  test('errors are glossary errors and Errors', () => {
    const e = new TooManyTerms(500);
    expect(e).toBeInstanceOf(GlossaryError);
    expect(e).toBeInstanceOf(Error);
    expect(e.name).toBe('TooManyTerms');
  });

  test('length counts grapheme clusters (Dart characters.length), not code points', async () => {
    const store = await open();
    const a = '\u{1D400}';
    await expect(store.add({text: a.repeat(64)})).resolves.toBeTruthy();
    await expect(store.add({text: 'x' + a.repeat(64)})).rejects.toBeInstanceOf(TooLong);
    // e + U+0301 stays two code points (no NFC here): 128 code points, 64 characters.
    const decomposed = 'e\u0301'.repeat(64);
    await expect(store.add({text: decomposed})).resolves.toBeTruthy();
    await expect(store.add({text: 'e\u0301'.repeat(65)})).rejects.toBeInstanceOf(TooLong);
    await expect(store.add({text: '\u{1F1FB}\u{1F1F3}'.repeat(64)})).resolves.toBeTruthy();
  });

  test('a trailing U+0085 is trimmed like the Dart reference', async () => {
    const store = await open();
    expect((await store.add({text: '\u0085Zalo\u0085'})).text).toBe('Zalo');
  });

  test('two corrupt values in the same second do not overwrite each other', async () => {
    kv.items.set(KEY, 'first');
    await open();
    kv.items.set(KEY, 'second');
    await open();
    expect([...kv.items.keys()].sort()).toEqual([ASIDE, `${ASIDE}-1`]);
    expect(new Set(kv.items.values())).toEqual(new Set(['first', 'second']));
  });

  test('concurrent changes are all kept', async () => {
    const store = await open();
    await Promise.all(Array.from({length: 20}, (_, i) => store.add({text: `term ${i}`})));
    expect(store.terms.length).toBe(20);
    expect((await open()).terms.length).toBe(20);
  });

  test('concurrent duplicates: the second is refused', async () => {
    const store = await open();
    const results = await Promise.allSettled([store.add({text: 'Zalo'}), store.add({text: 'zalo'})]);
    expect(results.map(r => r.status)).toEqual(['fulfilled', 'rejected']);
    expect(texts(store)).toEqual(['Zalo']);
  });

  test('a write failure is reported and changes nothing', async () => {
    const store = await open();
    await store.add({text: 'A'});
    const fired = jest.fn();
    store.changes.on('changed', fired);
    kv.failWrites = true;
    await expect(store.add({text: 'B'})).rejects.toBeInstanceOf(GlossaryWriteError);
    expect(texts(store)).toEqual(['A']);
    expect(fired).not.toHaveBeenCalled();
    kv.failWrites = false;
    await store.add({text: 'B'});
    expect(texts(await open())).toEqual(['A', 'B']);
  });

  test('corrupt data that cannot be moved aside still opens empty', async () => {
    kv.items.set(KEY, '{oops');
    kv.failWrites = true;
    const store = await open();
    expect(store.terms).toEqual([]);
    expect(store.recoveredFromCorruption).toBe(true);
  });

  test('a custom key keeps two glossaries apart', async () => {
    const a = await GlossaryStore.open(kv, {key: 'a'});
    await a.add({text: 'A'});
    expect((await GlossaryStore.open(kv, {key: 'b'})).terms).toEqual([]);
    expect(texts(await GlossaryStore.open(kv, {key: 'a'}))).toEqual(['A']);
  });
});

describe('AsyncStorage store', () => {
  test('round trip through the AsyncStorage key-value store', async () => {
    const storage = asyncStorageKeyValueStore();
    const store = await GlossaryStore.open(storage);
    await store.add({text: 'Bến Thành'});
    expect(texts(await GlossaryStore.open(storage))).toEqual(['Bến Thành']);
    expect(JSON.parse((await storage.getItem(KEY))!)).toHaveLength(1);
  });
});
