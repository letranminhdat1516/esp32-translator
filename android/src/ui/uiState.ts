// Port of app/lib/ui/conversation_state.dart: everything the screens read, as plain data, and the
// intents (callbacks) they call. P2.1 binds a controller by calling `update` of `useUiState` with
// the changed fields and by passing real intents to <App>; the screens never reach the engine.
import {useCallback, useReducer} from 'react';
import type {BoardState} from '../board/BoardLink';
import type {LanguagePack, Term} from '../core/model';
import type {AudioRoute} from '../engine/VoiceEngine';
import type {SessionState} from '../engine/sessionMachine';

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
  /** Stable key across renders. */
  readonly id: string;
  readonly source: string;
  readonly target: string;
  /** Recognised with low confidence: the translation is shown faint. */
  readonly unclear?: boolean;
  /** When the line was last spoken (ms since epoch): orders both sides into one stream. */
  readonly at: number;
}

/** How ready a listed language is (the marks of the language sheet). */
export interface LanguageMark {
  /** Models and voices are on the device: usable now. */
  readonly ready: boolean;
  /** Recognition goes over the network (the opt-in "online" recognizer). */
  readonly online: boolean;
}

export interface UiState {
  readonly phase: UiPhase;
  /** Status text for `preparing`, reason for `failed`. */
  readonly message: string;
  /** Rendered by the readiness view for `needsDownload` (carries the missing items). */
  readonly session: SessionState | null;
  readonly board: BoardState;
  /** The phone runs without a board: shows the "không có board" chip. */
  readonly noBoard: boolean;
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
  /** Readiness / online mark per offered language code. */
  readonly languageMarks: Readonly<Record<string, LanguageMark>>;
  /** The user opted in to the online recognizer (footer switch of the language sheet). */
  readonly onlineOptIn: boolean;
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
  noBoard: false,
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
  languageMarks: {},
  onlineOptIn: false,
  languageNames: {vi: 'Tiếng Việt'},
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

/** The Vietnamese validation messages (Dart `GlossaryMessages`). */
export const GlossaryMessages = {
  empty: 'Từ không được để trống',
  tooLong: 'Tối đa 64 ký tự',
  tooMany: 'Tối đa 500 từ',
  badCharacters: 'Có ký tự không hợp lệ',
  // Not in the Dart screen (it never mapped these two store errors); added for the same store.
  duplicate: 'Từ này đã có trong từ điển',
  tooManyVariants: 'Tối đa 8 cách viết khác',
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
  setOnlineOptIn(on: boolean): void;
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
  setOnlineOptIn: noop,
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
