// Port of app/lib/core/language_catalog.dart. Contract: shared/fixtures/language_catalog.json
// (shared/fixtures/README.md, "language_catalog.json — LanguageCatalog").
import {recognizerKinds, type Capabilities, type LanguagePack, type RecognizerKind} from './model';

export type Platform = 'ios' | 'android';

export interface LanguageCatalogOptions {
  /** The bundled language packs. */
  readonly packs: readonly LanguagePack[];
  /** What the phone reports (`VoiceEngine.capabilities(home)`). */
  readonly caps: Capabilities;
  readonly platform: Platform;
  /** Language codes the user agreed to send to the online OS recognizer (stored by the app). */
  readonly onlineConsent?: ReadonlySet<string>;
}

/**
 * Which languages the user can pick as "the other person's", and which recognizers to try for each
 * (R2, P3).
 *
 * Combines the bundled packs with what the phone reports. A language is offered when it works
 * fully: at least one usable recognizer and offline translation both ways with Vietnamese. On
 * Android the chain is the on-device OS recognizer (the engine reports it on API 33+), then
 * Whisper, then the online OS recognizer only for a language with stored consent; iOS never goes
 * online. Vietnamese is the home language and is never offered.
 */
export class LanguageCatalog {
  /** Code of the home language, which is always the wearer's. */
  static readonly homeCode = 'vi';

  /** The languages to list, sorted by label (lower-cased, UTF-16 order), ties by code. */
  readonly offered: readonly LanguagePack[];

  private readonly caps: Capabilities;
  private readonly onlineAllowed: boolean;
  private readonly consent: ReadonlySet<string>;

  /** Throws `RangeError` for a platform other than `ios` or `android`. */
  constructor({packs, caps, platform, onlineConsent = new Set()}: LanguageCatalogOptions) {
    if (platform !== 'ios' && platform !== 'android') {
      throw new RangeError(`platform must be 'ios' or 'android', not '${String(platform)}'`);
    }
    this.caps = caps;
    this.onlineAllowed = platform === 'android';
    this.consent = new Set(onlineConsent);
    const sorted = packs
      .filter(
        p =>
          p.code !== LanguageCatalog.homeCode &&
          this.chain(p.code).length > 0 &&
          caps.translatable.has(p.code),
      )
      .sort((a, b) => compare(a.label.toLowerCase(), b.label.toLowerCase()) || compare(a.code, b.code));
    this.offered = Object.freeze(sorted);
  }

  /**
   * The recognizers to try for `code`, best first: the OS on-device one, then Whisper, then (with
   * consent, Android only) the OS online one.
   */
  chain(code: string): readonly RecognizerKind[] {
    const have = Object.prototype.hasOwnProperty.call(this.caps.recognizers, code)
      ? this.caps.recognizers[code]
      : [];
    return Object.freeze(
      recognizerKinds.filter(
        kind => have.includes(kind) && (kind !== 'osOnline' || this.mayGoOnline(code)),
      ),
    );
  }

  private mayGoOnline(code: string): boolean {
    return this.onlineAllowed && this.consent.has(code);
  }
}

/** Dart `String.compareTo`: UTF-16 code unit order. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
