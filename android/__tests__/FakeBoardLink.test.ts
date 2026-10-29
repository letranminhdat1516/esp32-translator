// Port of app/test/board/fake_board_link_test.dart.
import {BoardControl, BoardLink, BoardState, boardStates} from '../src/board/BoardLink';
import {FakeBoardLink} from '../src/board/FakeBoardLink';
import {FontSets, boardInfoEquals, legacyBoardInfo} from '../src/core/model';

test('board states in order', () => {
  expect(boardStates).toEqual(['off', 'scanning', 'connecting', 'ready']);
});

test('records texts and mic calls in order', async () => {
  const link = new FakeBoardLink();
  await link.sendText('a', 'subtitle');
  await link.sendText('b', 'label');
  await link.setBoardMic(true);
  await link.setBoardMic(false);
  expect(link.sentTexts).toEqual([
    {text: 'a', kind: 'subtitle'},
    {text: 'b', kind: 'label'},
  ]);
  expect(link.micCalls).toEqual([true, false]);
});

test('default info and settable info', () => {
  const link = new FakeBoardLink();
  expect(boardInfoEquals(link.info, {protocolVersion: 0, fontSets: FontSets.latinVI})).toBe(true);
  expect(link.info).toBe(legacyBoardInfo);
  link.info = {protocolVersion: 1, fontSets: FontSets.cjk};
  expect(link.info.protocolVersion).toBe(1);
});

test('emits state, audio and control; currentState follows the state', () => {
  const link: BoardLink & FakeBoardLink = new FakeBoardLink();
  expect(link.currentState).toBe('off');
  const states: BoardState[] = [];
  const audio: Uint8Array[] = [];
  const control: BoardControl[] = [];
  link.on('state', s => states.push(s));
  link.on('audio', a => audio.push(a));
  link.on('control', c => control.push(c));
  link.emitState('ready');
  link.emitAudio(Uint8Array.from([1]));
  link.emitControl({type: 'micChanged', on: true});
  expect(states).toEqual(['ready']);
  expect(link.currentState).toBe('ready');
  expect(Array.from(audio[0])).toEqual([1]);
  expect(control).toEqual([{type: 'micChanged', on: true}]);
});

test('currentState is set before the subscribers run; unsubscribe stops delivery', () => {
  const link = new FakeBoardLink();
  const seen: BoardState[] = [];
  const off = link.on('state', s => seen.push(link.currentState === s ? s : 'off'));
  link.emitState('scanning');
  off();
  link.emitState('connecting');
  expect(seen).toEqual(['scanning']);
  expect(link.currentState).toBe('connecting');
  expect(link.listenerCount('state')).toBe(0);
});

test('scripted sendText failure', async () => {
  const link = new FakeBoardLink();
  link.failNextSend(new Error('write failed'));
  await expect(link.sendText('x', 'subtitle')).rejects.toThrow('write failed');
  await link.sendText('y', 'subtitle');
  expect(link.sentTexts).toEqual([{text: 'y', kind: 'subtitle'}]);
});
