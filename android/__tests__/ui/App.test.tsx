import React from 'react';
import {fireEvent, render, screen} from '@testing-library/react-native';
import App, {sampleState} from '../../App';
import {noopIntents} from '../../src/ui/uiState';
import {packs} from './helpers';

jest.mock('react-native-safe-area-context', () => require('react-native-safe-area-context/jest/mock').default);

const mockGet = jest.fn<Promise<string | null>, [string]>();
const mockSet = jest.fn<Promise<void>, [string, string]>();
jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {getItem: (k: string) => mockGet(k), setItem: (k: string, v: string) => mockSet(k, v)},
}));

const globals = globalThis as unknown as {__DEV__: boolean};

describe('App (development: sample intents)', () => {
  beforeEach(() => {
    mockGet.mockReset().mockResolvedValue(null);
    mockSet.mockReset().mockResolvedValue();
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => jest.restoreAllMocks());

  it('boots with the empty state, warns once, and opens the glossary and back', async () => {
    await render(<App />);
    expect(console.warn).toHaveBeenCalledTimes(1);
    expect(screen.getByText('Bắt đầu nghe')).toBeTruthy();
    await fireEvent.press(screen.getByLabelText('Cài đặt'));
    await fireEvent.press(screen.getByText('Từ điển riêng'));
    expect(await screen.findByText('Chưa có từ nào')).toBeTruthy();
    await fireEvent.press(screen.getByLabelText('Quay lại'));
    expect(await screen.findByText('Bắt đầu nghe')).toBeTruthy();
  });

  it('opens the language sheet from the header pill', async () => {
    await render(<App />);
    await fireEvent.press(screen.getByLabelText(/Tiếng Việt sang/));
    expect(await screen.findByText('Ngôn ngữ')).toBeTruthy();
  });

  it('applies the saved language on mount', async () => {
    mockGet.mockResolvedValue('ja');
    await render(<App initialState={{...sampleState, offeredPacks: packs}} />);
    await fireEvent.press(screen.getByLabelText(/Tiếng Việt sang/));
    expect(await screen.findByTestId('language-ja')).toBeTruthy();
    expect(screen.getAllByText('✓')).toHaveLength(1);
    const tick = screen.getByTestId('language-ja');
    expect(tick.props.accessibilityState?.selected).toBe(true);
  });

  it('a pick is saved', async () => {
    await render(<App initialState={{...sampleState, offeredPacks: packs}} />);
    await fireEvent.press(screen.getByLabelText(/Tiếng Việt sang/));
    await fireEvent.press(await screen.findByText('Français'));
    expect(mockSet).toHaveBeenCalledWith('pickedLanguage', 'fr');
  });
});

describe('App (production)', () => {
  const dev = globals.__DEV__;
  beforeEach(() => {
    globals.__DEV__ = false;
    mockGet.mockReset().mockResolvedValue(null);
    jest.spyOn(console, 'warn').mockImplementation(() => {});
    jest.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => {
    globals.__DEV__ = dev;
    jest.restoreAllMocks();
  });

  it('requires intents', async () => {
    await expect(render(<App />)).rejects.toThrow(/intents/);
  });

  it('runs with given intents and no warning', async () => {
    await render(<App intents={noopIntents} />);
    expect(screen.getByText('Bắt đầu nghe')).toBeTruthy();
    expect(console.warn).not.toHaveBeenCalled();
  });
});
