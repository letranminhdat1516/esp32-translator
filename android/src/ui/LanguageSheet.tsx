// Port of app/lib/ui/language_sheet.dart, plus the readiness / "online" marks and the footer that
// explains why a language may be missing (the online recognizer is an opt-in).
import React from 'react';
import {Modal, Pressable, ScrollView, StyleSheet, Switch, View} from 'react-native';
import type {LanguagePack} from '../core/model';
import {Chip, Txt} from './components';
import {Palette, Spacing, Type} from './theme';
import type {LanguageMark} from './uiState';

export interface LanguageListProps {
  packs: readonly LanguagePack[];
  currentCode: string | null;
  onPick: (code: string) => void;
  marks?: Readonly<Record<string, LanguageMark>>;
}

/** The list itself, shared with the "Chọn ngôn ngữ" step of the readiness view. */
export function LanguageList({packs, currentCode, onPick, marks = {}}: LanguageListProps) {
  return (
    <ScrollView contentContainerStyle={styles.list}>
      {packs.map(p => {
        const mark = marks[p.code];
        return (
          <Pressable
            key={p.code}
            testID={`language-${p.code}`}
            accessibilityRole="button"
            accessibilityLabel={p.label}
            onPress={() => onPick(p.code)}
            style={styles.row}>
            <View style={styles.rowText}>
              <Txt style={styles.rowTitle}>{p.label}</Txt>
              {p.labelLatin !== p.label ? <Txt style={styles.rowSub}>{p.labelLatin}</Txt> : null}
            </View>
            {mark?.online ? <Chip text="online" /> : null}
            {mark ? (
              <Txt style={[styles.mark, !mark.ready && styles.markNeeds]}>
                {mark.ready ? 'sẵn sàng' : 'cần tải'}
              </Txt>
            ) : null}
            {p.code === currentCode ? <Txt style={styles.tick}>✓</Txt> : null}
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

export interface LanguageSheetProps extends LanguageListProps {
  visible: boolean;
  onlineOptIn: boolean;
  onSetOnlineOptIn: (on: boolean) => void;
  /** Called before `onPick` when a language is picked, and on back / tap outside. */
  onClose: () => void;
}

/** Bottom sheet: the offered languages, the current one ticked. Persisting the pick is the caller's job. */
export function LanguageSheet({
  visible,
  packs,
  currentCode,
  marks,
  onlineOptIn,
  onSetOnlineOptIn,
  onPick,
  onClose,
}: LanguageSheetProps) {
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose} accessibilityLabel="Đóng" />
      <View style={styles.sheet}>
        <Txt style={styles.title}>Ngôn ngữ</Txt>
        <View style={styles.listBox}>
          <LanguageList
            packs={packs}
            currentCode={currentCode}
            marks={marks}
            onPick={code => {
              onClose();
              onPick(code);
            }}
          />
        </View>
        <View style={styles.footer}>
          <Txt style={styles.footerText}>
            Không thấy ngôn ngữ cần dùng? Máy chỉ liệt kê các ngôn ngữ nhận giọng được ngay trên máy.
            Bật nhận giọng online để thêm các ngôn ngữ khác: âm thanh sẽ được gửi qua mạng và ngôn
            ngữ đó được đánh dấu "online".
          </Txt>
          <View style={styles.optIn}>
            <Txt style={styles.optInText}>Nhận giọng online</Txt>
            <Switch
              accessibilityLabel="Nhận giọng online"
              value={onlineOptIn}
              onValueChange={onSetOnlineOptIn}
              trackColor={{false: Palette.faint, true: Palette.accent}}
              thumbColor={Palette.white}
            />
          </View>
        </View>
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
    paddingBottom: Spacing.l,
  },
  title: {
    fontSize: Type.title,
    paddingHorizontal: Spacing.xl,
    paddingTop: Spacing.xl,
    paddingBottom: Spacing.s,
  },
  listBox: {flexShrink: 1},
  list: {paddingBottom: Spacing.m},
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.s,
    paddingHorizontal: Spacing.xl,
    paddingVertical: Spacing.m,
  },
  rowText: {flex: 1},
  rowTitle: {fontSize: Type.row},
  rowSub: {fontSize: Type.secondary, color: Palette.muted},
  mark: {fontSize: Type.small, color: Palette.muted},
  markNeeds: {color: Palette.accentLight},
  tick: {fontSize: Type.row, color: Palette.accentLight},
  footer: {paddingHorizontal: Spacing.xl, paddingTop: Spacing.s, gap: Spacing.s},
  footerText: {fontSize: Type.small, color: Palette.muted},
  optIn: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  optInText: {fontSize: Type.body},
});
