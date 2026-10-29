// Port of app/lib/board/fake_board_link.dart: an in-memory BoardLink for tests. Records writes,
// emits on demand.
import {BoardInfo, legacyBoardInfo} from '../core/model';
import {TypedEmitter, Unsubscribe} from '../engine/VoiceEngine';
import {BoardControl, BoardLink, BoardLinkEvents, BoardState} from './BoardLink';
import {TextKind} from './protocol';

export class FakeBoardLink implements BoardLink {
  /** Every successful `sendText` call, in order. */
  readonly sentTexts: Array<{text: string; kind: TextKind}> = [];
  /** Every `setBoardMic` call, in order. */
  readonly micCalls: boolean[] = [];

  info: BoardInfo = legacyBoardInfo;

  private state: BoardState = 'off';
  private readonly events = new TypedEmitter<BoardLinkEvents>();
  private sendFailure: {error: unknown} | null = null;

  get currentState(): BoardState {
    return this.state;
  }

  on<K extends keyof BoardLinkEvents>(
    event: K,
    handler: (payload: BoardLinkEvents[K]) => void,
  ): Unsubscribe {
    return this.events.on(event, handler);
  }

  /** Number of subscribers to `event` (to check that callers unsubscribe). */
  listenerCount(event: keyof BoardLinkEvents): number {
    return this.events.listenerCount(event);
  }

  /** Makes the next `sendText` reject with `error` (not recorded). */
  failNextSend(error: unknown): void {
    this.sendFailure = {error};
  }

  async sendText(text: string, kind: TextKind): Promise<void> {
    if (this.sendFailure) {
      const {error} = this.sendFailure;
      this.sendFailure = null;
      throw error;
    }
    this.sentTexts.push({text, kind});
  }

  async setBoardMic(on: boolean): Promise<void> {
    this.micCalls.push(on);
  }

  /** Sets `currentState`, then notifies the subscribers. */
  emitState(s: BoardState): void {
    this.state = s;
    this.events.emit('state', s);
  }

  emitAudio(data: Uint8Array): void {
    this.events.emit('audio', data);
  }

  emitControl(c: BoardControl): void {
    this.events.emit('control', c);
  }
}
