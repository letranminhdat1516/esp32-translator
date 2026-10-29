#!/usr/bin/env node
// Term harness (P2.5, R10) for the Android app: runs shared/fixtures/terms/<lang>.tsv through the
// app's own TypeScript TermProtector (src/core/termProtector.ts) with each placeholder shape and
// prints the term-accuracy table. ML Kit runs only on the phone, so the device run is two passes
// (tool/term_harness.sh does all of it):
//
//   node scripts/term-harness.mjs --translator record:requests.tsv   # what the phone must translate
//   (adb push requests.tsv; TermHarnessTest translates it with ML Kit; adb pull responses.tsv)
//   node scripts/term-harness.mjs --translator replay:responses.tsv [--out results.md] [--write-packs]
//
// Smoke test on the Mac, no phone: --translator fake (identity) or --translator scripted (halves
// `[[`/`]]` and `__`, so those shapes lose their placeholders).
//
// Options: --lang en,ja (default: every corpus file), --engine <name for the table title>,
// --out <file> (also write the table there), --write-packs (replay only: writes the best shape per
// language into shared/languages/<lang>.json as "androidPlaceholder"; run `npm run sync-shared`
// afterwards).
//
// Why the TS route and not a Kotlin port of the protector: the app masks with this exact code, the
// shared fixtures pin it, and a third copy in Kotlin would be one more thing to keep identical. The
// Kotlin test only wraps ML Kit (requests in, translations out). TypeScript is transpiled on load
// with the project's own `typescript` package (no extra dependency).
import fs from 'node:fs';
import path from 'node:path';
import {registerHooks} from 'node:module';
import {fileURLToPath, pathToFileURL} from 'node:url';
import ts from 'typescript';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const shared = path.resolve(root, '../shared');

// Load src/**/*.ts directly: extensionless relative imports resolve to .ts, and .ts is transpiled.
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith('.') && context.parentURL?.endsWith('.ts') && !path.extname(specifier)) {
      return next(`${specifier}.ts`, context);
    }
    return next(specifier, context);
  },
  load(url, context, next) {
    if (!url.endsWith('.ts')) {
      return next(url, context);
    }
    const source = fs.readFileSync(fileURLToPath(url), 'utf8');
    const {outputText} = ts.transpileModule(source, {
      compilerOptions: {module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false},
      fileName: fileURLToPath(url),
    });
    return {format: 'module', source: outputText, shortCircuit: true};
  },
});

const h = await import(pathToFileURL(path.join(root, 'src/harness/termHarness.ts')).href);

function parseArgs(argv) {
  const o = {translator: null, langs: null, engine: null, out: null, writePacks: false};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) {
        fail(`${a} needs a value`);
      }
      return argv[++i];
    };
    if (a === '--translator') o.translator = value();
    else if (a === '--lang') o.langs = value().split(',').filter(Boolean);
    else if (a === '--engine') o.engine = value();
    else if (a === '--out') o.out = value();
    else if (a === '--write-packs') o.writePacks = true;
    else fail(`unknown option ${a}`);
  }
  if (!o.translator) fail('--translator fake | scripted | record:<file> | replay:<file> is required');
  return o;
}

function fail(message) {
  console.error(`term-harness: ${message}`);
  process.exit(2);
}

const key = (from, to, text) => `${from}\t${to}\t${h.escapeField(text)}`;

const opts = parseArgs(process.argv.slice(2));
const corpusDir = path.join(shared, 'fixtures', 'terms');
const langs =
  opts.langs ?? fs.readdirSync(corpusDir).filter(f => f.endsWith('.tsv')).map(f => f.slice(0, -4)).sort();
const lines = langs.flatMap(lang => {
  const file = path.join(corpusDir, `${lang}.tsv`);
  if (!fs.existsSync(file)) fail(`no corpus ${file}`);
  return h.parseCorpus(fs.readFileSync(file, 'utf8'), lang);
});

const [kind, file] = [opts.translator.split(':')[0], opts.translator.slice(opts.translator.indexOf(':') + 1)];
let translate;
let engine = opts.engine;
const recorded = new Set();
if (kind === 'fake') {
  translate = async text => text;
  engine ??= 'fake (identity)';
} else if (kind === 'scripted') {
  translate = async text => h.scripted(text);
  engine ??= 'fake (scripted)';
} else if (kind === 'record' && file !== opts.translator) {
  // Every masked text, and the plain source for the fallback (the dummy answer loses the placeholder).
  translate = async (text, from, to) => {
    recorded.add(key(from, to, text));
    return '';
  };
} else if (kind === 'replay' && file !== opts.translator) {
  // Responses: from<TAB>to<TAB>text<TAB>translation, or a translation starting with "!" for an error.
  const answers = new Map();
  for (const row of fs.readFileSync(file, 'utf8').split('\n')) {
    const cols = row.replace(/\r$/, '').split('\t');
    if (cols.length === 4) answers.set(cols.slice(0, 3).join('\t'), cols[3]);
  }
  translate = async (text, from, to) => {
    const answer = answers.get(key(from, to, text));
    if (answer === undefined) throw new Error(`no response for ${from}>${to} ${JSON.stringify(text)}`);
    if (answer.startsWith('!')) throw new Error(`translator: ${h.unescapeField(answer.slice(1))}`);
    return h.unescapeField(answer);
  };
  engine ??= 'ML Kit (Android)';
} else {
  fail(`unknown translator ${opts.translator}`);
}

const {results, errors} = await h.runCorpus(lines, h.SHAPES, translate);

if (kind === 'record') {
  fs.writeFileSync(file, [...recorded].join('\n') + '\n');
  console.log(`wrote ${recorded.size} requests (${lines.length} lines × ${h.SHAPES.length} shapes + plain) to ${file}`);
  process.exit(0);
}

const table = h.report(results, h.SHAPES, engine);
process.stdout.write(table);
if (errors.length > 0) {
  console.error(`\n${errors.length} translation errors (counted as failures):`);
  for (const e of errors.slice(0, 20)) console.error(`  ${e}`);
}
if (opts.out) {
  fs.writeFileSync(opts.out, table);
  console.error(`table written to ${opts.out}`);
}
if (opts.writePacks) {
  if (kind !== 'replay') fail('--write-packs needs real translations (--translator replay:<file>)');
  for (const [lang, best] of h.bestShapes(results, h.SHAPES)) {
    const pack = path.join(shared, 'languages', `${lang}.json`);
    if (!fs.existsSync(pack)) {
      console.error(`no pack ${pack}: skipped`);
      continue;
    }
    fs.writeFileSync(pack, h.setPlaceholder(fs.readFileSync(pack, 'utf8'), 'androidPlaceholder', best.shape));
    console.error(`${lang}: androidPlaceholder = ${best.shape}`);
  }
  console.error('packs changed: run `npm run sync-shared` and the test suites');
}
