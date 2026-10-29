// Test-only loader for the shared fixtures and language packs (shared/fixtures/README.md).
// Reads the files with Node fs; the app bundles shared/ separately.
import fs from 'fs';
import path from 'path';

/** Root of the language-neutral data shared with the Swift port and the Dart reference. */
export const sharedDir = path.resolve(__dirname, '../../shared');

// JSON values as the fixtures hold them.
export type Json = null | boolean | number | string | Json[] | JsonObject;
export type JsonObject = {[key: string]: Json};

/** Reads `shared/fixtures/<name>.json`. */
export function loadFixture(name: string): JsonObject {
  return JSON.parse(
    fs.readFileSync(path.join(sharedDir, 'fixtures', `${name}.json`), 'utf8'),
  ) as JsonObject;
}

/** The text of `shared/languages/<code>.json`. */
export function readPackJson(code: string): string {
  return fs.readFileSync(path.join(sharedDir, 'languages', `${code}.json`), 'utf8');
}

/** Codes of every `shared/languages/*.json`, sorted. */
export function shippedPackCodes(): string[] {
  return fs
    .readdirSync(path.join(sharedDir, 'languages'))
    .filter(f => f.endsWith('.json'))
    .map(f => f.slice(0, -'.json'.length))
    .sort();
}

/** The cases of `group` in a fixture, as JSON objects (absent -> empty). */
export function casesOf(fixture: JsonObject, group: string): JsonObject[] {
  return (fixture[group] as JsonObject[] | undefined) ?? [];
}

/** Lower-case hex without separators, e.g. `0300586e`. */
export function hexOf(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

/** Bytes of a hex string; spaces are ignored. */
export function bytesOf(hex: string): Uint8Array {
  const h = hex.replace(/ /g, '');
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  }
  return out;
}
