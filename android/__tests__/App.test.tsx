/**
 * The product App (no props): builds the graph once through src/app/bootstrap.ts, starts the
 * controller and renders its state; the screens call the controller's intents.
 *
 * @format
 */

import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';
import App from '../App';
import {FakeBoardLink} from '../src/board/FakeBoardLink';
import {BoardGlyphSets} from '../src/core/boardGlyphs';
import {bundledPacks} from '../src/core/sharedAssets';
import {ConversationController, MemoryPickStore} from '../src/engine/ConversationController';
import {FakeVoiceEngine} from '../src/engine/FakeVoiceEngine';
import {t} from '../src/ui/copy';

jest.mock('react-native-safe-area-context', () => require('react-native-safe-area-context/jest/mock').default);

const mockGraph = jest.fn();
jest.mock('../src/app/bootstrap', () => ({createAppGraph: () => mockGraph()}));

const flush = async () => {
  for (let i = 0; i < 200; i++) {
    await Promise.resolve();
  }
};

function graph() {
  const engine = new FakeVoiceEngine({
    recognizers: {en: ['whisper']},
    translatable: new Set(['vi', 'en']),
    vietnameseVoice: true,
  });
  engine.translations.set('Good morning', 'Chào buổi sáng');
  const board = new FakeBoardLink();
  const controller = new ConversationController({
    engine,
    board,
    packs: bundledPacks(),
    pickStore: new MemoryPickStore(),
    glyphs: new BoardGlyphSets(),
    log: () => {},
  });
  return {engine, board, controller};
}

describe('App (the product)', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
    mockGraph.mockReset();
  });

  it('builds the graph once, runs the controller and shows "no board" while listening', async () => {
    const g = graph();
    const destroy = jest.fn(() => g.controller.dispose());
    mockGraph.mockReturnValue({controller: g.controller, destroy});
    const view = await render(<App />);
    await act(flush);
    expect(mockGraph).toHaveBeenCalledTimes(1);
    expect(g.engine.starts).toHaveLength(1);
    expect(screen.getByLabelText(t('header.pair', {label: 'English'}))).toBeTruthy();

    // Opening the app starts listening.
    expect(g.engine.micStates).toEqual([true]);
    expect(screen.getByText(t('control.stop'))).toBeTruthy();
    expect(screen.getByText(t('chip.noBoard'))).toBeTruthy();
    await fireEvent.press(screen.getByText(t('control.stop')));
    await act(flush);
    expect(g.engine.micStates).toEqual([true, false]);
    await fireEvent.press(screen.getByText(t('control.start')));
    await act(flush);
    expect(g.engine.micStates).toEqual([true, false, true]);

    await act(async () => {
      g.engine.emit('theirs', {text: 'Good morning', confidence: 0.9, generation: 0});
      await flush();
    });
    expect(screen.getByText('Good morning')).toBeTruthy();
    expect(screen.getByText('Chào buổi sáng')).toBeTruthy();

    await act(async () => {
      g.board.emitState('ready');
      await flush();
    });
    expect(screen.queryByText(t('chip.noBoard'))).toBeNull();

    await view.unmount();
    expect(destroy).toHaveBeenCalledTimes(1);
    expect(g.engine.stopCount).toBe(1);
    expect(mockGraph).toHaveBeenCalledTimes(1);
  });

  it('uses an injected controller instead of the real graph', async () => {
    const g = graph();
    await render(<App controller={g.controller} />);
    await act(flush);
    expect(mockGraph).not.toHaveBeenCalled();
    expect(g.engine.starts).toHaveLength(1);
  });

  it('shows the Bluetooth note when the permission is refused; the phone side runs', async () => {
    const engine = new FakeVoiceEngine({
      recognizers: {en: ['whisper']},
      translatable: new Set(['vi', 'en']),
      vietnameseVoice: true,
    });
    const controller = new ConversationController({
      engine,
      board: new FakeBoardLink(),
      packs: bundledPacks(),
      pickStore: new MemoryPickStore(),
      glyphs: new BoardGlyphSets(),
      permissions: {session: async () => true, board: async () => false},
      log: () => {},
    });
    await render(<App controller={controller} />);
    await act(flush);
    expect(screen.getByText(t('permission.bluetooth'))).toBeTruthy();
    expect(engine.starts).toHaveLength(1);
  });
});
