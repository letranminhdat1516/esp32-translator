import fs from 'fs';
import path from 'path';

const root = path.resolve(__dirname, '..');
const read = (p: string) => fs.readFileSync(path.join(root, p), 'utf8');

describe('skeleton config', () => {
  it('declares strict TypeScript explicitly', () => {
    const tsconfig = JSON.parse(
      read('tsconfig.json').replace(/^\s*\/\/.*$/gm, ''),
    );
    expect(tsconfig.compilerOptions.strict).toBe(true);
  });

  it('uses the vn.cicca.livetranslator package', () => {
    expect(read('android/app/build.gradle')).toContain(
      'applicationId "vn.cicca.livetranslator"',
    );
  });

  it('can import the BLE and storage libraries', () => {
    expect(() => require.resolve('react-native-ble-plx')).not.toThrow();
    expect(() =>
      require.resolve('@react-native-async-storage/async-storage'),
    ).not.toThrow();
  });
});
