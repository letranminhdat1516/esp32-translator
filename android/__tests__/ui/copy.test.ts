import fs from 'fs';
import path from 'path';
import vi from '../../../shared/copy/vi.json';
import {t} from '../../src/ui/copy';

const uiDir = path.join(__dirname, '../../src/ui');
const files = [
  ...fs
    .readdirSync(uiDir)
    .filter(f => /\.tsx?$/.test(f))
    .map(f => path.join(uiDir, f)),
  path.join(__dirname, '../../App.tsx'),
];
const stripComments = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
const source = (f: string) => stripComments(fs.readFileSync(f, 'utf8'));
const vietnamese =
  /[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]/i;

describe('shared/copy/vi.json', () => {
  it('every key the screens use exists, and every key is used', () => {
    const used = new Set<string>();
    for (const f of files) {
      if (f.endsWith('copy.ts')) {
        continue;
      }
      for (const m of source(f).matchAll(/\bt\(\s*'([^']+)'/g)) {
        used.add(m[1]);
      }
      // Keys passed around as data: 'glossary.error.x' style literals.
      for (const m of source(f).matchAll(/'((?:[a-zA-Z]+\.)+[a-zA-Z0-9]+)'/g)) {
        if (m[1] in vi) {
          used.add(m[1]);
        }
      }
    }
    const keys = Object.keys(vi);
    expect([...used].filter(k => !keys.includes(k))).toEqual([]);
    expect(keys.filter(k => !used.has(k))).toEqual([]);
  });

  it('no screen contains a hard-coded Vietnamese literal', () => {
    for (const f of files) {
      if (f.endsWith('copy.ts')) {
        continue;
      }
      const hits = source(f)
        .split('\n')
        .filter(l => vietnamese.test(l));
      expect({file: path.basename(f), hits}).toEqual({file: path.basename(f), hits: []});
    }
  });

  it('fills {placeholders}', () => {
    expect(t('missing.translation', {from: 'English', to: 'Tiếng Việt'})).toBe('Bản dịch English → Tiếng Việt');
    expect(t('readiness.downloadingPercent', {percent: 42})).toBe('Đang tải… 42%');
  });
});
