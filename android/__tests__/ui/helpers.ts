import type {LanguagePack} from '../../src/core/model';
import {UiIntents, UiLine, UiState, emptyUiState} from '../../src/ui/uiState';

export function pack(
  code: string,
  label: string,
  latin: string,
  script: LanguagePack['script'] = 'latin',
): LanguagePack {
  return {
    code,
    appleLocale: 'x',
    androidLocale: 'x',
    whisperCode: code,
    label,
    labelLatin: latin,
    script,
    minConfidence: null,
    recognition: [],
    beforeTranslation: [],
    terms: [],
    hints: [],
  };
}

export const packs = [
  pack('en', 'English', 'English'),
  pack('ja', '日本語', 'Japanese', 'cjk'),
  pack('fr', 'Français', 'French'),
];

export const t0 = Date.UTC(2026, 9, 26, 10);
export const line = (
  id: string,
  source: string,
  target: string,
  sec: number,
  unclear = false,
): UiLine => ({id, source, target, at: t0 + sec * 1000, unclear});

/** Intents that log their calls. */
export function makeIntents() {
  const log: string[] = [];
  const intents: UiIntents = {
    toggleBoardMic: () => {
      log.push('mic');
    },
    startListening: () => {
      log.push('start');
    },
    stopListening: () => {
      log.push('stop');
    },
    clearHistory: () => {
      log.push('clear');
    },
    onDownload: () => {
      log.push('download');
    },
    onRetry: () => {
      log.push('retry');
    },
    pickLanguage: c => {
      log.push(`pick ${c}`);
    },
    setOnlineAllowed: (code, on) => {
      log.push(`online ${code} ${on}`);
    },
    openTtsSettings: () => {
      log.push('tts');
    },
    addTerm: t => {
      log.push(`add ${t}`);
    },
    updateTerm: (id, t) => {
      log.push(`update ${id} ${t}`);
    },
    deleteTerm: id => {
      log.push(`delete ${id}`);
    },
  };
  return {log, intents};
}

export const state = (over: Partial<UiState> = {}): UiState => ({
  ...emptyUiState,
  phase: 'running',
  board: 'ready',
  languageLabel: 'English',
  currentCode: 'en',
  languageNames: {en: 'English', vi: 'Tiếng Việt'},
  ...over,
});
