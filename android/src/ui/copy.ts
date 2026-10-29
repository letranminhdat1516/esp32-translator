// The Vietnamese UI copy, shared with the Swift app: shared/copy/vi.json (flat keys). Screens never
// contain a Vietnamese literal; they call `t('key', {vars})`. Placeholders are written `{name}`.
import vi from '../../../shared/copy/vi.json';

export type CopyKey = keyof typeof vi;

export function t(key: CopyKey, vars: Readonly<Record<string, string | number>> = {}): string {
  return vi[key].replace(/\{(\w+)\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m));
}
