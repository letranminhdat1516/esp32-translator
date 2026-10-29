import React from 'react';
import {StyleSheet} from 'react-native';
import {fireEvent, render, screen} from '@testing-library/react-native';
import {ConversationScreen} from '../../src/ui/ConversationScreen';
import {Palette} from '../../src/ui/theme';
import {UiState} from '../../src/ui/uiState';
import {line, makeIntents, packs, state} from './helpers';

async function setup(s: UiState) {
  const {log, intents} = makeIntents();
  const nav: string[] = [];
  const utils = await render(
    <ConversationScreen
      state={s}
      intents={intents}
      onOpenLanguages={() => nav.push('languages')}
      onOpenGlossary={() => nav.push('glossary')}
    />,
  );
  return {log, nav, ...utils};
}
const colorOf = (text: string) => StyleSheet.flatten(screen.getByText(text).props.style).color;
const listenBg = () => StyleSheet.flatten(screen.getByTestId('listenButton').props.style).backgroundColor;

describe('ConversationScreen', () => {
  it('idle: "Bắt đầu nghe" starts, then "Dừng nghe" stops', async () => {
    const a = await setup(state());
    await fireEvent.press(screen.getByText('Bắt đầu nghe'));
    expect(a.log).toEqual(['start']);
    await a.unmount();
    const b = await setup(state({listening: true}));
    expect(screen.queryByText('Bắt đầu nghe')).toBeNull();
    await fireEvent.press(screen.getByText('Dừng nghe'));
    expect(b.log).toEqual(['stop']);
  });

  it('listen button uses accent while listening and surface otherwise', async () => {
    const a = await setup(state());
    expect(listenBg()).toBe(Palette.surface);
    await a.unmount();
    await setup(state({listening: true}));
    expect(listenBg()).toBe(Palette.accent);
  });

  it('listen button is disabled until the phase is running', async () => {
    const a = await setup(state({phase: 'idle'}));
    await fireEvent.press(screen.getByText('Bắt đầu nghe'));
    expect(a.log).toEqual([]);
  });

  it('trash is disabled without history', async () => {
    const a = await setup(state());
    await fireEvent.press(screen.getByLabelText('Xoá hội thoại'));
    expect(screen.queryByText('Xoá toàn bộ hội thoại?')).toBeNull();
    expect(a.log).toEqual([]);
  });

  it('trash asks first; Huỷ keeps, Xoá clears', async () => {
    const a = await setup(state({theirLines: [line('a', 'Hello', 'Xin chào', 0)]}));
    await fireEvent.press(screen.getByLabelText('Xoá hội thoại'));
    expect(screen.getByText('Xoá toàn bộ hội thoại?')).toBeTruthy();
    expect(a.log).toEqual([]);
    await fireEvent.press(screen.getByText('Huỷ'));
    expect(a.log).toEqual([]);
    expect(screen.queryByText('Xoá toàn bộ hội thoại?')).toBeNull();
    await fireEvent.press(screen.getByLabelText('Xoá hội thoại'));
    await fireEvent.press(screen.getByText('Xoá'));
    expect(a.log).toEqual(['clear']);
    expect(screen.queryByText('Xoá toàn bộ hội thoại?')).toBeNull();
  });

  it('settings menu: three items, clear asks first', async () => {
    const a = await setup(state({theirLines: [line('a', 'Hello', 'Xin chào', 0)]}));
    await fireEvent.press(screen.getByLabelText('Cài đặt'));
    expect(screen.getByText('Ngôn ngữ')).toBeTruthy();
    expect(screen.getByText('Từ điển riêng')).toBeTruthy();
    expect(screen.queryByText(/relay/)).toBeNull();
    await fireEvent.press(screen.getByText('Xoá hội thoại'));
    expect(a.log).toEqual([]);
    expect(screen.getByText('Xoá toàn bộ hội thoại?')).toBeTruthy();
    await fireEvent.press(screen.getByText('Xoá'));
    expect(a.log).toEqual(['clear']);
  });

  it('settings menu opens languages and glossary', async () => {
    const a = await setup(state());
    await fireEvent.press(screen.getByLabelText('Cài đặt'));
    await fireEvent.press(screen.getByText('Ngôn ngữ'));
    await fireEvent.press(screen.getByLabelText('Cài đặt'));
    await fireEvent.press(screen.getByText('Từ điển riêng'));
    expect(a.nav).toEqual(['languages', 'glossary']);
  });

  it('settings menu clear is disabled without history', async () => {
    const a = await setup(state());
    await fireEvent.press(screen.getByLabelText('Cài đặt'));
    await fireEvent.press(screen.getByText('Xoá hội thoại'));
    expect(screen.queryByText('Xoá toàn bộ hội thoại?')).toBeNull();
    expect(a.log).toEqual([]);
  });

  it('header pill shows the pair and opens the language sheet', async () => {
    const a = await setup(state());
    expect(screen.getByText('Tiếng Việt')).toBeTruthy();
    expect(screen.getByText('English')).toBeTruthy();
    await fireEvent.press(screen.getByLabelText('Tiếng Việt sang English'));
    expect(a.nav).toEqual(['languages']);
  });

  it('board mic button toggles and is disabled until ready', async () => {
    const a = await setup(state());
    await fireEvent.press(screen.getByLabelText('Tắt mic của board'));
    expect(a.log).toEqual(['mic']);
    await a.unmount();
    const b = await setup(state({board: 'scanning'}));
    await fireEvent.press(screen.getByLabelText('Tắt mic của board'));
    expect(b.log).toEqual([]);
    await b.unmount();
    await setup(state({boardMicOn: false}));
    expect(screen.getByLabelText('Bật mic của board')).toBeTruthy();
  });

  it('status line: waiting / listening and board text', async () => {
    const a = await setup(state());
    expect(screen.getByText('Đang chờ')).toBeTruthy();
    expect(screen.getByText('· Board đã kết nối')).toBeTruthy();
    await a.unmount();
    const b = await setup(state({listening: true, boardMicOn: false}));
    expect(screen.getByText('Đang nghe')).toBeTruthy();
    expect(screen.getByText('· Board đã kết nối · mic tắt')).toBeTruthy();
    await b.unmount();
    for (const [board, text] of [
      ['off', '· Bluetooth đang tắt'],
      ['scanning', '· Đang tìm board…'],
      ['connecting', '· Đang kết nối…'],
    ] as const) {
      const r = await setup(state({board}));
      expect(screen.getByText(text)).toBeTruthy();
      await r.unmount();
    }
  });

  it('lines are ordered by time across both sides', async () => {
    await setup(
      state({
        theirLines: [line('a', 'late', 'muộn', 30), line('b', 'early', 'sớm', 10)],
        myLines: [line('c', 'giữa', 'middle', 20)],
      }),
    );
    const texts = screen.getAllByTestId('bubbleTarget').map(n => n.props.children);
    expect(texts).toEqual(['sớm', 'middle', 'muộn']);
    expect(screen.getAllByText('Họ nói')).toHaveLength(2);
    expect(screen.getAllByText('Bạn nói')).toHaveLength(1);
  });

  it('my lines with an empty source are hidden', async () => {
    await setup(state({myLines: [line('c', '', 'hidden', 5)]}));
    expect(screen.queryByText('hidden')).toBeNull();
    expect(screen.queryByText('Bạn nói')).toBeNull();
  });

  it('partials are italic and faint', async () => {
    await setup(state({listening: true, theirPartial: 'hel', myPartial: 'xin'}));
    for (const p of ['hel', 'xin']) {
      const style = StyleSheet.flatten(screen.getByText(p).props.style);
      expect(style.fontStyle).toBe('italic');
      expect(style.color).toBe(Palette.faint);
    }
  });

  it('unclear targets are dimmed, clear ones are text coloured', async () => {
    await setup(
      state({
        theirLines: [line('a', 'mumble', 'lầm bầm', 1, true), line('b', 'hello', 'xin chào', 2)],
      }),
    );
    expect(colorOf('lầm bầm')).toBe(Palette.faint);
    expect(colorOf('xin chào')).toBe(Palette.text);
    expect(colorOf('mumble')).toBe(Palette.muted);
  });

  it('empty hints match the Swift app', async () => {
    const a = await setup(state());
    expect(screen.getByText('Chạm "Bắt đầu nghe" trước khi nói')).toBeTruthy();
    expect(
      screen.getByText(
        'Người đối diện nói vào board, bạn nghe tiếng Việt qua AirPods. ' +
          'Bạn nói tiếng Việt, họ đọc phụ đề trên board.',
      ),
    ).toBeTruthy();
    await a.unmount();
    const b = await setup(state({listening: true}));
    expect(screen.getByText('Cứ nói đi')).toBeTruthy();
    await b.unmount();
    await setup(state({theirPartial: 'x'}));
    expect(screen.queryByText('Chạm "Bắt đầu nghe" trước khi nói')).toBeNull();
  });

  it('"online" chip follows onlineRecognizer', async () => {
    const a = await setup(state());
    expect(screen.queryByText('online')).toBeNull();
    await a.unmount();
    await setup(state({onlineRecognizer: true}));
    expect(screen.getByText('online')).toBeTruthy();
  });

  it('"mic điện thoại" chip only while listening on the phone mic', async () => {
    for (const [listening, micRoute, shown] of [
      [true, 'headset', false],
      [true, 'phoneMic', true],
      [false, 'phoneMic', false],
    ] as const) {
      const r = await setup(state({listening, micRoute}));
      expect(screen.queryByText('mic điện thoại') !== null).toBe(shown);
      await r.unmount();
    }
  });

  it('"không có board" chip only while listening without a ready board (as the Swift app)', async () => {
    for (const [listening, board, shown] of [
      [true, 'off', true],
      [true, 'scanning', true],
      [true, 'connecting', true],
      [false, 'off', false],
      [true, 'ready', false],
    ] as const) {
      const r = await setup(state({listening, board}));
      expect(screen.queryByText('không có board') !== null).toBe(shown);
      await r.unmount();
    }
  });

  it('chips carry the accessibility texts of the Swift app', async () => {
    await setup(state({listening: true, board: 'off', onlineRecognizer: true, micRoute: 'phoneMic'}));
    expect(screen.getByLabelText('Đang nhận giọng qua mạng')).toBeTruthy();
    expect(screen.getByLabelText('Đang dùng mic điện thoại')).toBeTruthy();
    expect(screen.getByLabelText('Chưa kết nối board')).toBeTruthy();
  });

  it('the board mic is disabled without a ready board', async () => {
    const b = await setup(state({board: 'off'}));
    await fireEvent.press(screen.getByLabelText('Tắt mic của board'));
    expect(b.log).toEqual([]);
  });

  it('a my-line and a their-line with the same id both render', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    await setup(
      state({theirLines: [line('1', 'hello', 'xin chào', 1)], myLines: [line('1', 'chào', 'hi', 2)]}),
    );
    expect(screen.getAllByTestId('bubbleTarget')).toHaveLength(2);
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it('TTS banner explains and opens the system settings', async () => {
    const a = await setup(state());
    expect(screen.queryByText('Mở cài đặt')).toBeNull();
    await a.unmount();
    const b = await setup(state({ttsVoiceMissing: true}));
    expect(screen.getByText('Chưa có giọng đọc tiếng Việt. Bản dịch chỉ hiện dạng chữ.')).toBeTruthy();
    await fireEvent.press(screen.getByText('Mở cài đặt'));
    expect(b.log).toEqual(['tts']);
  });

  it('preparing shows its message, no control bar', async () => {
    await setup(state({phase: 'preparing', message: 'Đang tải mô hình…'}));
    expect(screen.getByText('Đang tải mô hình…')).toBeTruthy();
    expect(screen.queryByText('Bắt đầu nghe')).toBeNull();
  });

  it('failed shows reason and Thử lại', async () => {
    const a = await setup(state({phase: 'failed', message: 'Không mở được mic'}));
    expect(screen.getByText('Không khởi động được')).toBeTruthy();
    expect(screen.getByText('Không mở được mic')).toBeTruthy();
    await fireEvent.press(screen.getByText('Thử lại'));
    expect(a.log).toEqual(['retry']);
  });

  it('needsDownload renders the readiness view', async () => {
    const a = await setup(
      state({
        phase: 'needsDownload',
        session: {
          type: 'needsDownload',
          code: 'en',
          error: null,
          missing: [{kind: 'translation', language: 'en', from: 'en', to: 'vi'}],
        },
      }),
    );
    expect(screen.getByText('Bản dịch English → Tiếng Việt')).toBeTruthy();
    await fireEvent.press(screen.getByText('Tải về'));
    expect(a.log).toEqual(['download']);
  });

  it('Choosing lists offeredPacks and a tap calls pickLanguage', async () => {
    const a = await setup(
      state({phase: 'needsDownload', session: {type: 'choosing', reason: null}, offeredPacks: packs}),
    );
    await fireEvent.press(screen.getByText('日本語'));
    expect(a.log).toEqual(['pick ja']);
  });

  it('Downloading shows the progress', async () => {
    await setup(
      state({phase: 'needsDownload', session: {type: 'downloading', code: 'en'}, downloadProgress: 0.5}),
    );
    expect(screen.getByText('Đang tải… 50%')).toBeTruthy();
  });

  it('snapshot: conversation, listening, online, phone mic', async () => {
    const r = await setup(
      state({
        listening: true,
        onlineRecognizer: true,
        micRoute: 'phoneMic',
        theirLines: [
          line('a', 'Where is the train station?', 'Ga tàu ở đâu vậy?', 0),
          line('b', 'mumble mumble', 'lầm bầm gì đó', 20, true),
        ],
        myLines: [line('c', 'Đi thẳng rồi rẽ phải nhé', 'Go straight, then turn right.', 10)],
        theirPartial: 'and how far is it',
        myPartial: 'khoảng năm phút đi bộ',
      }),
    );
    expect(r.toJSON()).toMatchSnapshot();
  });

  it('snapshot: empty and failed', async () => {
    const a = await setup(state());
    expect(a.toJSON()).toMatchSnapshot('empty');
    await a.unmount();
    const b = await setup(state({phase: 'failed', message: 'Không mở được mic', board: 'off'}));
    expect(b.toJSON()).toMatchSnapshot('failed');
  });
});
