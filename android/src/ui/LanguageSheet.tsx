// Port of app/lib/ui/language_sheet.dart with the footer of ios/Sources/UI/LanguageSheet.swift:
// the "online" chip on online-only languages, why a language is missing, and the online opt-in.
import React, {useContext} from 'react';
import {Modal, Pressable, ScrollView, StyleSheet, Switch, View} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import type {LanguagePack} from '../core/model';
import {Chip, Txt} from './components';
import {t} from './copy';
import {Palette, Spacing, Type} from './theme';

export interface LanguageListProps {
  packs: readonly LanguagePack[];
  currentCode: string | null;
  onPick: (code: string) => void;
  /** Codes marked with the "online" chip. */
  onlineCodes?: readonly string[];
}

/** The list itself, shared with the "Chọn ngôn ngữ" step of the readiness view. */
export function LanguageList({packs, currentCode, onPick, onlineCodes = []}: LanguageListProps) {
  return (
    <ScrollView contentContainerStyle={styles.list}>
      {packs.map(p => (
        <Pressable
          key={p.code}
          testID={`language-${p.code}`}
          accessibilityRole="button"
          accessibilityLabel={p.label}
          accessibilityState={{selected: p.code === currentCode}}
          onPress={() => onPick(p.code)}
          style={styles.row}>
          <View style={styles.rowText}>
            <View style={styles.rowTitleLine}>
              <Txt style={styles.rowTitle}>{p.label}</Txt>
              {onlineCodes.includes(p.code) ? <Chip text={t('chip.online')} /> : null}
            </View>
            {p.labelLatin !== p.label ? <Txt style={styles.rowSub}>{p.labelLatin}</Txt> : null}
          </View>
          {p.code === currentCode ? <Txt style={styles.tick}>✓</Txt> : null}
        </Pressable>
      ))}
    </ScrollView>
  );
}

export interface LanguageSheetProps extends LanguageListProps {
  visible: boolean;
  /** Not offered, but possible with the online recognizer: listed in the footer with a switch each. */
  onlineCandidates: readonly LanguagePack[];
  onlineAllowed: readonly string[];
  onSetOnlineAllowed: (code: string, on: boolean) => void;
  /** Called before `onPick` when a language is picked, and on back / tap outside. */
  onClose: () => void;
}

/** Bottom sheet: the offered languages, the current one ticked. Persisting the pick is the caller's job. */
export function LanguageSheet({
  visible,
  packs,
  currentCode,
  onlineCodes,
  onlineCandidates,
  onlineAllowed,
  onSetOnlineAllowed,
  onPick,
  onClose,
}: LanguageSheetProps) {
  const bottom = useContext(SafeAreaInsetsContext)?.bottom ?? 0;
  return (
    <Modal visible={visible} transparent statusBarTranslucent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose} accessibilityLabel={t('language.close')} />
      <View style={[styles.sheet, {paddingBottom: Spacing.l + bottom}]}>
        <Txt style={styles.title}>{t('language.sheetTitle')}</Txt>
        <ScrollView style={styles.scroll}>
          <LanguageList
            packs={packs}
            currentCode={currentCode}
            onlineCodes={onlineCodes}
            onPick={code => {
              onClose();
              onPick(code);
            }}
          />
          {onlineCandidates.length > 0 ? (
            <View style={styles.footer}>
              <Txt style={styles.footerText}>
                {t('language.why', {names: onlineCandidates.map(p => p.label).join(', ')})}
              </Txt>
              <Txt style={styles.optInTitle}>{t('language.optInTitle')}</Txt>
              <Txt style={styles.footerText}>{t('language.optInNote')}</Txt>
              {onlineCandidates.map(p => (
                <View key={p.code} style={styles.optIn}>
                  <Txt style={styles.optInText}>{p.label}</Txt>
                  <Switch
                    testID={`online-${p.code}`}
                    accessibilityLabel={p.label}
                    value={onlineAllowed.includes(p.code)}
                    onValueChange={on => onSetOnlineAllowed(p.code, on)}
                    trackColor={{false: Palette.faint, true: Palette.accent}}
                    thumbColor={Palette.white}
                  />
                </View>
              ))}
            </View>
          ) : null}
        </ScrollView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {flex: 1, backgroundColor: 'rgba(0,0,0,0.5)'},
  sheet: {
    backgroundColor: Palette.surface,
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    maxHeight: '80%',
  },
  title: {
    fontSize: Type.title,
    paddingHorizontal: Spacing.xl,
    paddingTop: Spacing.xl,
    paddingBottom: Spacing.s,
  },
  scroll: {flexGrow: 0},
  list: {paddingBottom: Spacing.m},
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.s,
    paddingHorizontal: Spacing.xl,
    paddingVertical: Spacing.m,
  },
  rowText: {flex: 1},
  rowTitleLine: {flexDirection: 'row', alignItems: 'center', gap: Spacing.s},
  rowTitle: {fontSize: Type.row},
  rowSub: {fontSize: Type.secondary, color: Palette.muted},
  tick: {fontSize: Type.row, color: Palette.accentLight},
  footer: {paddingHorizontal: Spacing.xl, paddingTop: Spacing.l, gap: 10},
  footerText: {fontSize: Type.small, color: Palette.muted},
  optInTitle: {fontSize: Type.body, marginTop: Spacing.xs},
  optIn: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  optInText: {fontSize: Type.body},
});
