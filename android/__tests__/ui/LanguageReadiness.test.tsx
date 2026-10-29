import React from 'react';
import {fireEvent, render, screen, within} from '@testing-library/react-native';
import {LanguageSheet} from '../../src/ui/LanguageSheet';
import {ReadinessView} from '../../src/ui/ReadinessView';
import {SessionState} from '../../src/ui/uiState';
import {packs} from './helpers';

describe('LanguageSheet', () => {
  const base = {
    visible: true,
    packs,
    currentCode: 'ja' as string | null,
    onlineOptIn: false,
    marks: {},
    onPick: () => {},
    onSetOnlineOptIn: () => {},
    onClose: () => {},
  };

  it('lists the packs, ticks the current one, reports the pick', async () => {
    const picked: string[] = [];
    await render(<LanguageSheet {...base} onPick={c => picked.push(c)} />);
    expect(screen.getByText('Ngôn ngữ')).toBeTruthy();
    for (const t of ['English', '日本語', 'Français', 'Japanese']) {
      expect(screen.getByText(t)).toBeTruthy();
    }
    expect(screen.getAllByText('✓')).toHaveLength(1);
    expect(within(screen.getByTestId('language-ja')).getByText('✓')).toBeTruthy();
    await fireEvent.press(screen.getByText('Français'));
    expect(picked).toEqual(['fr']);
  });

  it('picking closes the sheet (onClose before onPick)', async () => {
    const order: string[] = [];
    await render(
      <LanguageSheet {...base} onPick={c => order.push(`pick ${c}`)} onClose={() => order.push('close')} />,
    );
    await fireEvent.press(screen.getByText('Français'));
    expect(order).toEqual(['close', 'pick fr']);
  });

  it('is not rendered when not visible', async () => {
    await render(<LanguageSheet {...base} visible={false} />);
    expect(screen.queryByText('Ngôn ngữ')).toBeNull();
  });

  it('marks readiness and the online recognizer per language', async () => {
    await render(
      <LanguageSheet
        {...base}
        marks={{
          en: {ready: true, online: false},
          ja: {ready: false, online: false},
          fr: {ready: true, online: true},
        }}
      />,
    );
    expect(within(screen.getByTestId('language-en')).getByText('sẵn sàng')).toBeTruthy();
    expect(within(screen.getByTestId('language-ja')).getByText('cần tải')).toBeTruthy();
    expect(within(screen.getByTestId('language-fr')).getByText('online')).toBeTruthy();
    expect(within(screen.getByTestId('language-en')).queryByText('online')).toBeNull();
  });

  it('footer explains missing languages and toggles the online opt-in', async () => {
    const calls: boolean[] = [];
    await render(<LanguageSheet {...base} onSetOnlineOptIn={on => calls.push(on)} />);
    expect(screen.getByText(/Không thấy ngôn ngữ cần dùng/)).toBeTruthy();
    await fireEvent(screen.getByLabelText('Nhận giọng online'), 'valueChange', true);
    expect(calls).toEqual([true]);
  });
});

describe('ReadinessView', () => {
  const labels = {en: 'English', vi: 'Tiếng Việt'};
  async function show(s: SessionState, progress: number | null = null) {
    const log: string[] = [];
    const r = await render(
      <ReadinessView
        state={s}
        onDownload={() => log.push('download')}
        onRetry={() => log.push('retry')}
        offered={packs}
        onPick={c => log.push(`pick ${c}`)}
        labels={labels}
        progress={progress}
      />,
    );
    return {log, ...r};
  }

  it('NeedsDownload lists every missing item in Vietnamese', async () => {
    const {log} = await show({
      type: 'needsDownload',
      code: 'en',
      error: null,
      missing: [
        {kind: 'speechModel', language: 'en'},
        {kind: 'translation', language: 'en', from: 'en', to: 'vi'},
        {kind: 'translation', language: 'en', from: 'vi', to: 'en'},
        {kind: 'ttsVoice', language: 'vi'},
      ],
    });
    expect(screen.getByText('Cần tải về trước khi dùng')).toBeTruthy();
    expect(screen.getByText('Mô hình nhận giọng')).toBeTruthy();
    expect(screen.getByText('Bản dịch English → Tiếng Việt')).toBeTruthy();
    expect(screen.getByText('Bản dịch Tiếng Việt → English')).toBeTruthy();
    expect(screen.getByText('Giọng đọc tiếng Việt')).toBeTruthy();
    await fireEvent.press(screen.getByText('Tải về'));
    expect(log).toEqual(['download']);
  });

  it('a missing label shows the code as is', async () => {
    await show({
      type: 'needsDownload',
      code: 'ja',
      error: null,
      missing: [{kind: 'translation', language: 'ja', from: 'ja', to: 'vi'}],
    });
    expect(screen.getByText('Bản dịch ja → Tiếng Việt')).toBeTruthy();
  });

  it('Downloading shows progress', async () => {
    const a = await show({type: 'downloading', code: 'en'});
    expect(screen.getByText('Đang tải…')).toBeTruthy();
    expect(screen.getByTestId('progressBar').props.accessibilityValue).toBeUndefined();
    await a.unmount();
    await show({type: 'downloading', code: 'en'}, 0.42);
    expect(screen.getByText('Đang tải… 42%')).toBeTruthy();
    expect(screen.getByTestId('progressBar').props.accessibilityValue).toEqual({min: 0, max: 100, now: 42});
  });

  it('a failed download shows the error and Thử lại that downloads again', async () => {
    const {log} = await show({
      type: 'needsDownload',
      code: 'en',
      error: 'timeout',
      missing: [{kind: 'speechModel', language: 'en'}],
    });
    expect(screen.getByText('Chưa tải xong. Kiểm tra mạng rồi thử lại.')).toBeTruthy();
    expect(screen.getByText('timeout')).toBeTruthy();
    await fireEvent.press(screen.getByText('Thử lại'));
    expect(log).toEqual(['download']);
  });

  it('Failed shows the not-ready reason and Thử lại retries', async () => {
    const {log} = await show({type: 'failed', code: 'en', reason: 'recognizer stopped'});
    expect(screen.getByText('Không khởi động được')).toBeTruthy();
    expect(screen.getByText('recognizer stopped')).toBeTruthy();
    await fireEvent.press(screen.getByText('Thử lại'));
    expect(log).toEqual(['retry']);
  });

  it('Choosing lists the packs and reports the pick', async () => {
    const {log} = await show({type: 'choosing', reason: null});
    expect(screen.getByText('Chọn ngôn ngữ')).toBeTruthy();
    expect(screen.queryByText(/không còn dùng được/)).toBeNull();
    await fireEvent.press(screen.getByText('日本語'));
    expect(log).toEqual(['pick ja']);
  });

  it('Choosing after an unavailable saved language says so', async () => {
    await show({type: 'choosing', reason: 'unavailable'});
    expect(screen.getByText(/không còn dùng được/)).toBeTruthy();
  });

  it('Checking and Preparing show a spinner', async () => {
    for (const s of [
      {type: 'checking', code: 'en'},
      {type: 'preparing', code: 'en', restarts: 0},
    ] as const) {
      const r = await show(s);
      expect(screen.getByTestId('spinner')).toBeTruthy();
      await r.unmount();
    }
  });

  it('snapshot: needs download and downloading', async () => {
    const a = await show({
      type: 'needsDownload',
      code: 'en',
      error: null,
      missing: [{kind: 'speechModel', language: 'en'}],
    });
    expect(a.toJSON()).toMatchSnapshot('needsDownload');
    await a.unmount();
    const b = await show({type: 'downloading', code: 'en'}, 0.5);
    expect(b.toJSON()).toMatchSnapshot('downloading');
  });
});
