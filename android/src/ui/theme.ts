// "Phụ đề" theme, ported from app/lib/ui/theme.dart (values from ios/Sources/UI/ContentView.swift).
import {StyleSheet, TextStyle} from 'react-native';

export const Palette = {
  ground: '#000000',
  surface: '#16171A',
  text: '#E3EAF0',
  muted: '#8A919C',
  faint: '#5E646D',
  accent: '#1E6FD9',
  accentLight: '#4C8FE8',
  error: '#E5645A',
  /** Dart `Colors.redAccent`: destructive actions. */
  destructive: '#FF5252',
  white: '#FFFFFF',
} as const;

/**
 * Be Vietnam Pro SemiBold, the only weight bundled (android/android/app/src/main/assets/fonts/
 * BeVietnamPro-SemiBold.ttf, copied by hand from app/assets/fonts; React Native on Android finds
 * it by file name). Because there is a single weight, `fontWeight` is not used.
 */
export const fontFamily = 'BeVietnamPro-SemiBold';

/** Font sizes used by the Dart screens. */
export const Type = {
  chip: 11,
  caption: 12,
  small: 13,
  secondary: 14,
  body: 15,
  button: 16,
  row: 17,
  title: 18,
  line: 20,
} as const;

export const Spacing = {
  xs: 4,
  s: 8,
  m: 12,
  l: 16,
  xl: 20,
  xxl: 24,
  /** Gap between conversation lines. */
  line: 26,
} as const;

export const Layout = {
  bubbleMaxWidth: 300,
  pillHeight: 40,
  roundButton: 52,
  settingsButton: 44,
  listenHeight: 56,
} as const;

export const baseText: TextStyle = {fontFamily, color: Palette.text};

export const common = StyleSheet.create({
  screen: {flex: 1, backgroundColor: Palette.ground},
});
