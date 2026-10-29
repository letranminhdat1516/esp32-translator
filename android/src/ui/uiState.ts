// Port of app/lib/ui/conversation_state.dart: everything the screens read, as plain data, and the
// intents (callbacks) they call. P2.1 binds a controller by calling `update` of `useUiState` with
// the changed fields and by passing real intents to <App>; the screens never reach the engine.
import {useCallback, useReducer} from 'react';
import type {BoardState} from '../board/BoardLink';
import type {LanguagePack, Term} from '../core/model';
import type {AudioRoute} from '../engine/VoiceEngine';
import type {SessionState} from '../engine/sessionMachine';
import {t} from './copy';

export type {BoardState, AudioRoute, SessionState};

/** What the conversation screen shows besides the conversation (Dart `UiPhase`). */
export type UiPhase =
  /** Not started yet: the screen is shown, listening is disabled. */
  | 'idle'
  /** A language pack or model is missing: `session` carries what the readiness view renders. */
  | 'needsDownload'
  /** Starting up; `message` is the status text. */
  | 'preparing'
  /** Ready: listening can start. */
  | 'running'
  /** Could not start; `message` is the reason. */
  | 'failed';

/** One line of the conversation (theirs or mine). */
export interface UiLine {
  /**
   * Stable key across renders. Ids are per side: a their-line and a my-line may share an id (the
   * screen keys them `t:<id>` / `m:<id>`), but must be unique within `theirLines` / `myLines`.
   */
  readonly id: string;
  readonly source: string;
  readonly target: string;
  /** Recognised with low confidence: the translation is shown faint. */
  readonly unclear?: boolean;
  /** When the line was last spoken (ms since epoch): orders both sides into one stream. */
  readonly at: number;
}

export interface UiState {
  readonly phase: UiPhase;
  /** Status text for `preparing`, reason for `failed`. */
  readonly message: string;
  /** Rendered by the readiness view for `needsDownload` (carries the missing items). */
  readonly session: SessionState | null;
  readonly board: BoardState;
  readonly boardMicOn: boolean;
  readonly theirLines: readonly UiLine[];
  readonly myLines: readonly UiLine[];
  readonly theirPartial: string;
  readonly myPartial: string;
  /** A conversation is going on. */
  readonly listening: boolean;
  /** The picked language's label: the header shows "Tiếng Việt ⇄ <label>". */
  readonly languageLabel: string;
  /** Code of the picked language (ticked in the sheet). */
  readonly currentCode: string | null;
  /** The recognizer sends audio to the network: shows the "online" chip. */
  readonly onlineRecognizer: boolean;
  /** Where "my" audio comes from; 'phoneMic' shows the "mic điện thoại" chip while listening. */
  readonly micRoute: AudioRoute;
  /** Languages listed while the session is choosing and in the language sheet. */
  readonly offeredPacks: readonly LanguagePack[];
  /** Offered only through the online recognizer (marked "online" in the list). */
  readonly onlineCodes: readonly string[];
  /** Not offered, but would work with the online recognizer: the footer lists them with the opt-in. */
  readonly onlineCandidates: readonly LanguagePack[];
  /** Languages the user allowed the online recognizer for. */
  readonly onlineAllowed: readonly string[];
  /** Display name per language code, including the home language: used in "Bản dịch A → B". */
  readonly languageNames: Readonly<Record<string, string>>;
  /** 0..1 while downloading; null when the platform reports none. */
  readonly downloadProgress: number | null;
  /** No Vietnamese system TTS voice: shows the banner with the system-settings button. */
  readonly ttsVoiceMissing: boolean;
  /** The user's glossary (built-in terms are listed read-only). */
  readonly glossaryTerms: readonly Term[];
}

export const emptyUiState: UiState = {
  phase: 'idle',
  message: '',
  session: null,
  board: 'off',
  boardMicOn: true,
  theirLines: [],
  myLines: [],
  theirPartial: '',
  myPartial: '',
  listening: false,
  languageLabel: '',
  currentCode: null,
  onlineRecognizer: false,
  micRoute: 'headset',
  offeredPacks: [],
  onlineCodes: [],
  onlineCandidates: [],
  onlineAllowed: [],
  languageNames: {vi: t('header.home')},
  downloadProgress: null,
  ttsVoiceMissing: false,
  glossaryTerms: [],
};

export const hasHistory = (s: UiState): boolean =>
  s.theirLines.length > 0 || s.myLines.length > 0;

/** Thrown by the glossary intents when a term is rejected; `message` is shown under the field. */
export class GlossaryValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GlossaryValidationError';
  }
}

/** The Vietnamese validation messages (shared/copy/vi.json; Dart `GlossaryMessages` + two more). */
export const GlossaryMessages = {
  empty: t('glossary.error.empty'),
  tooLong: t('glossary.error.tooLong'),
  tooMany: t('glossary.error.tooMany'),
  badCharacters: t('glossary.error.badCharacters'),
  duplicate: t('glossary.error.duplicate'),
  tooManyVariants: t('glossary.error.tooManyVariants'),
} as const;

/** Maps a store rejection (error names of shared/fixtures/glossary.json) to its message. */
export function glossaryMessageFor(error: string): string | undefined {
  switch (error) {
    case 'EmptyText':
      return GlossaryMessages.empty;
    case 'TooLong':
      return GlossaryMessages.tooLong;
    case 'TooManyTerms':
      return GlossaryMessages.tooMany;
    case 'ForbiddenCharacter':
      return GlossaryMessages.badCharacters;
    case 'DuplicateTerm':
      return GlossaryMessages.duplicate;
    case 'TooManyVariants':
      return GlossaryMessages.tooManyVariants;
    default:
      return undefined;
  }
}

/** Callbacks of the screens. P2.1 implements them; the relay is gone (no Claude relay). */
export interface UiIntents {
  toggleBoardMic(): void;
  startListening(): void;
  stopListening(): void;
  /** Called after the user confirmed the dialog. */
  clearHistory(): void;
  /** Download button of the readiness view. */
  onDownload(): void;
  /** "Thử lại" of `failed` and of a failed download. */
  onRetry(): void;
  /** A language picked in the sheet or in the readiness view. */
  pickLanguage(code: string): void;
  /** Allows or forbids the online recognizer for one language (footer of the language sheet). */
  setOnlineAllowed(code: string, on: boolean): void;
  /** Opens the system text-to-speech settings (TTS-voice banner). */
  openTtsSettings(): void;
  /** May throw `GlossaryValidationError`. */
  addTerm(text: string): void | Promise<void>;
  /** May throw `GlossaryValidationError`. */
  updateTerm(id: string, text: string): void | Promise<void>;
  deleteTerm(id: string): void | Promise<void>;
}

const noop = () => {};
export const noopIntents: UiIntents = {
  toggleBoardMic: noop,
  startListening: noop,
  stopListening: noop,
  clearHistory: noop,
  onDownload: noop,
  onRetry: noop,
  pickLanguage: noop,
  setOnlineAllowed: noop,
  openTtsSettings: noop,
  addTerm: noop,
  updateTerm: noop,
  deleteTerm: noop,
};

type Patch = Partial<UiState> | ((s: UiState) => Partial<UiState>);

/**
 * The UI store: plain React state. `update` merges changed fields (or the result of a function of
 * the current state). A controller keeps `update` and calls it from engine events.
 */
export function useUiState(initial: UiState = emptyUiState) {
  const [state, dispatch] = useReducer(
    (s: UiState, patch: Patch): UiState => ({
      ...s,
      ...(typeof patch === 'function' ? patch(s) : patch),
    }),
    initial,
  );
  const update = useCallback((patch: Patch) => dispatch(patch), []);
  return {state, update};
}
