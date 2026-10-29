// Port of app/lib/board/board_link.dart: the phone's side of the subtitle board. Implemented on
// react-native-ble-plx by BleBoardLink (track T2); FakeBoardLink for tests.
import {BoardInfo} from '../core/model';
import {Unsubscribe} from '../engine/VoiceEngine';
import {TextKind} from './protocol';

/** Connection state of the board link. */
export type BoardState = 'off' | 'scanning' | 'connecting' | 'ready';
export const boardStates: readonly BoardState[] = ['off', 'scanning', 'connecting', 'ready'];

/**
 * An event the board sends on the control characteristic. `micChanged`: the board's mic was
 * switched by the on-screen button (control notify, first byte non-zero = on); `ESPLink.onMicChange`.
 */
export type BoardControl = {readonly type: 'micChanged'; readonly on: boolean};

/** Event name → payload of the board link. */
export interface BoardLinkEvents {
  state: BoardState;
  /** Audio packets from the board mic (`…0002` notifications). */
  audio: Uint8Array;
  /** Board-originated control events. */
  control: BoardControl;
}

export interface BoardLink {
  /** The latest state (also emitted as `state`), for a subscriber that arrives after `ready`. */
  readonly currentState: BoardState;

  /**
   * What the board can render. Without a `…0005` characteristic (older firmware) this is
   * `legacyBoardInfo` (protocol 0, latinVI).
   */
  readonly info: BoardInfo;

  /** Frames (`frameText`) and writes `text`; a new message replaces an unsent one. */
  sendText(text: string, kind: TextKind): Promise<void>;

  /** Switches the board's mic (control characteristic write). */
  setBoardMic(on: boolean): Promise<void>;

  on<K extends keyof BoardLinkEvents>(
    event: K,
    handler: (payload: BoardLinkEvents[K]) => void,
  ): Unsubscribe;
}
