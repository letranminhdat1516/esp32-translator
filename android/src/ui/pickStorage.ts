// Persists the picked language code (AsyncStorage). Failures are swallowed: a pick that is not
// saved only means the language sheet opens again next time. The module is required lazily so
// the screens work (and are testable) where the native storage module is absent.
const KEY = 'pickedLanguage';

type Storage = {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
};

function storage(): Storage | null {
  try {
    const mod = require('@react-native-async-storage/async-storage');
    return (mod.default ?? mod) as Storage;
  } catch {
    return null;
  }
}

export async function loadPickedLanguage(): Promise<string | null> {
  try {
    return (await storage()?.getItem(KEY)) ?? null;
  } catch {
    return null;
  }
}

export async function savePickedLanguage(code: string): Promise<void> {
  try {
    await storage()?.setItem(KEY, code);
  } catch {
    // see above
  }
}
