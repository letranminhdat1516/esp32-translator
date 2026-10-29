#!/usr/bin/env node
// Copies the language-neutral data in ../shared into src/shared-generated/ as JSON modules that
// Metro can bundle (Metro does not reach outside the project root, and it cannot import .txt).
// Run by `npm run sync-shared` and before every `npm test` (`pretest`).
//
//   languages.json   { "<code>": <shared/languages/<code>.json as an object> }, codes sorted
//   boardGlyphs.json { "cjk": "<cjk.txt text>", "hangul": "...", "thai": "..." } (parsed at runtime)
//   translit.json    shared/fixtures/translit.json (the transliteration tables, data)
//
// The output is committed: a fresh clone builds with Gradle/Metro without running npm scripts.
// __tests__/sharedAssets.test.ts fails when it differs from shared/ (run this script to fix).
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const shared = path.resolve(here, '../../shared');
const out = path.resolve(here, '../src/shared-generated');

/** The generated files, name -> JSON value. */
function generate() {
  const langDir = path.join(shared, 'languages');
  const languages = {};
  for (const f of fs.readdirSync(langDir).filter(n => n.endsWith('.json')).sort()) {
    languages[f.slice(0, -'.json'.length)] = JSON.parse(
      fs.readFileSync(path.join(langDir, f), 'utf8'),
    );
  }
  const glyphDir = path.join(shared, 'board_glyphs');
  const boardGlyphs = {};
  for (const name of ['cjk', 'hangul', 'thai']) {
    boardGlyphs[name] = fs.readFileSync(path.join(glyphDir, `${name}.txt`), 'utf8');
  }
  const translit = JSON.parse(
    fs.readFileSync(path.join(shared, 'fixtures', 'translit.json'), 'utf8'),
  );
  return {
    'languages.json': languages,
    'boardGlyphs.json': boardGlyphs,
    'translit.json': translit,
  };
}

fs.mkdirSync(out, {recursive: true});
for (const [name, value] of Object.entries(generate())) {
  const file = path.join(out, name);
  const text = JSON.stringify(value, null, 1) + '\n';
  const old = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (old !== text) {
    fs.writeFileSync(file, text);
    console.log(`sync-shared: wrote src/shared-generated/${name}`);
  }
}
