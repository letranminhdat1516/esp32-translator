import React from 'react';
import {fireEvent, render, screen} from '@testing-library/react-native';
import App from '../../App';

jest.mock('react-native-safe-area-context', () => require('react-native-safe-area-context/jest/mock').default);

describe('App', () => {
  it('boots with the empty state and opens the glossary and back', async () => {
    await render(<App />);
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
    expect(await screen.findByText(/Không thấy ngôn ngữ cần dùng/)).toBeTruthy();
  });
});
