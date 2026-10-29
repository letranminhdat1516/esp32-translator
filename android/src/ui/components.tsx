// Small shared pieces of the "Phụ đề" screens.
import React from 'react';
import {
  Pressable,
  StyleProp,
  StyleSheet,
  Text,
  TextProps,
  TextStyle,
  View,
  ViewStyle,
} from 'react-native';
import {Palette, Spacing, Type, baseText} from './theme';

/** Text in the app font and colour. */
export function Txt({style, ...rest}: TextProps) {
  return <Text {...rest} style={[baseText, style]} />;
}

/** Small outlined tag in the status line. */
export function Chip({text}: {text: string}) {
  return (
    <View style={styles.chip}>
      <Txt style={styles.chipText}>{text}</Txt>
    </View>
  );
}

export function PrimaryButton({
  text,
  onPress,
  style,
}: {
  text: string;
  onPress: () => void;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={text}
      onPress={onPress}
      style={[styles.primary, style]}>
      <Txt style={styles.primaryText}>{text}</Txt>
    </Pressable>
  );
}

export function TextButton({
  text,
  onPress,
  color = Palette.accentLight,
}: {
  text: string;
  onPress: () => void;
  color?: string;
}) {
  const textStyle: TextStyle = {color, fontSize: Type.body};
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={text}
      onPress={onPress}
      style={styles.textButton}>
      <Txt style={textStyle}>{text}</Txt>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  chip: {
    paddingHorizontal: Spacing.s,
    paddingVertical: 2,
    borderRadius: 999,
    borderWidth: 1,
    borderColor: 'rgba(76,143,232,0.6)',
  },
  chipText: {fontSize: Type.chip, color: Palette.accentLight},
  primary: {
    backgroundColor: Palette.accent,
    borderRadius: 999,
    paddingHorizontal: 28,
    paddingVertical: 14,
    alignItems: 'center',
  },
  primaryText: {color: Palette.white, fontSize: Type.body},
  textButton: {paddingHorizontal: Spacing.m, paddingVertical: Spacing.s},
});
