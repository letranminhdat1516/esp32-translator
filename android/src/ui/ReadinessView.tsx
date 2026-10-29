// Port of app/lib/ui/readiness_view.dart: the part of the session that comes before the
// conversation: choosing a language, checking, missing downloads, downloading, failure.
import React from 'react';
import {ActivityIndicator, ScrollView, StyleSheet, View, ViewStyle} from 'react-native';
import type {LanguagePack} from '../core/model';
import type {MissingMsg} from '../engine/VoiceEngine';
import type {SessionState} from '../engine/sessionMachine';
import {PrimaryButton, Txt} from './components';
import {LanguageList} from './LanguageSheet';
import {Palette, Spacing, Type} from './theme';

export interface ReadinessViewProps {
  state: SessionState;
  onDownload: () => void;
  onRetry: () => void;
  /** Packs listed while choosing. */
  offered?: readonly LanguagePack[];
  onPick?: (code: string) => void;
  /** Display name per language code, used in "Bản dịch A → B". A missing code is shown as is. */
  labels?: Readonly<Record<string, string>>;
  /** 0..1 while downloading; null when the platform reports none. */
  progress?: number | null;
}

export function ReadinessView({
  state,
  onDownload,
  onRetry,
  offered = [],
  onPick,
  labels = {},
  progress = null,
}: ReadinessViewProps) {
  const label = (code: string | null | undefined) => (code == null ? '' : labels[code] ?? code);

  /** The Vietnamese name of one missing item. */
  const missingText = (m: MissingMsg): string => {
    switch (m.kind) {
      case 'speechModel':
        return 'Mô hình nhận giọng';
      case 'translation':
        return `Bản dịch ${label(m.from ?? m.language)} → ${label(m.to)}`;
      case 'ttsVoice':
        return 'Giọng đọc tiếng Việt';
    }
  };

  switch (state.type) {
    case 'choosing':
      return (
        <View style={styles.fill}>
          <View style={styles.chooseHead}>
            <Txt style={styles.title}>Chọn ngôn ngữ</Txt>
            {state.reason === 'unavailable' ? (
              <Txt style={styles.hintAccent}>
                Ngôn ngữ đã chọn trước đó không còn dùng được trên máy này.
              </Txt>
            ) : null}
          </View>
          <LanguageList packs={offered} currentCode={null} onPick={onPick ?? (() => {})} />
        </View>
      );
    case 'needsDownload': {
      const failed = state.error !== null;
      return (
        <Centered>
          <Txt style={styles.bigIcon}>⭳</Txt>
          <Txt style={[styles.title, styles.center]}>Cần tải về trước khi dùng</Txt>
          <View style={styles.gap12} />
          {state.missing.map((m, i) => (
            <Txt key={i} style={[styles.item, styles.center]}>
              {missingText(m)}
            </Txt>
          ))}
          <View style={styles.gap12} />
          <Txt style={[styles.item, styles.center]}>
            Tải một lần, sau đó dịch hoàn toàn trên máy: không cần mạng và nhanh hơn.
          </Txt>
          {failed ? (
            <>
              <View style={styles.gap12} />
              <Txt style={[styles.hintAccent, styles.center]}>
                Chưa tải xong. Kiểm tra mạng rồi thử lại.
              </Txt>
              {state.error ? <Txt style={[styles.errorDetail, styles.center]}>{state.error}</Txt> : null}
            </>
          ) : null}
          <View style={styles.gap16} />
          <PrimaryButton text={failed ? 'Thử lại' : 'Tải về'} onPress={onDownload} />
        </Centered>
      );
    }
    case 'downloading': {
      const fillWidth: ViewStyle = {width: progress === null ? '30%' : `${Math.round(progress * 100)}%`};
      return (
        <Centered>
          <View
            testID="progressBar"
            style={styles.track}
            accessibilityRole="progressbar"
            accessibilityValue={
              progress === null ? undefined : {min: 0, max: 100, now: Math.round(progress * 100)}
            }>
            <View
              style={[styles.fillBar, fillWidth]}
            />
          </View>
          <View style={styles.gap16} />
          <Txt style={styles.item}>
            {progress === null ? 'Đang tải…' : `Đang tải… ${Math.round(progress * 100)}%`}
          </Txt>
        </Centered>
      );
    }
    case 'failed':
      return (
        <Centered>
          <Txt style={styles.bigIcon}>⚠</Txt>
          <Txt style={styles.title}>Không khởi động được</Txt>
          <View style={styles.gap8} />
          <Txt style={[styles.item, styles.center]}>{state.reason}</Txt>
          <View style={styles.gap16} />
          <PrimaryButton text="Thử lại" onPress={onRetry} />
        </Centered>
      );
    case 'loading':
    case 'checking':
    case 'preparing':
    case 'running':
    case 'switching':
      return (
        <View style={styles.spinner}>
          <ActivityIndicator testID="spinner" color={Palette.muted} />
        </View>
      );
  }
}

function Centered({children}: {children: React.ReactNode}) {
  return (
    <View style={styles.fill}>
      <ScrollView contentContainerStyle={styles.centered}>{children}</ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: {flex: 1},
  centered: {flexGrow: 1, justifyContent: 'center', alignItems: 'center', padding: Spacing.xxl},
  spinner: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  chooseHead: {paddingHorizontal: Spacing.xl, paddingTop: Spacing.xxl, paddingBottom: Spacing.s},
  title: {fontSize: Type.title},
  center: {textAlign: 'center'},
  item: {fontSize: Type.body, color: Palette.muted, paddingVertical: 3},
  hintAccent: {fontSize: Type.secondary, color: Palette.accentLight, marginTop: 6},
  errorDetail: {fontSize: Type.small, color: Palette.faint, marginTop: Spacing.xs},
  bigIcon: {fontSize: 40, color: Palette.accentLight, marginBottom: Spacing.l},
  gap8: {height: Spacing.s},
  gap12: {height: Spacing.m},
  gap16: {height: Spacing.l},
  track: {width: 220, height: 4, borderRadius: 2, backgroundColor: Palette.surface, overflow: 'hidden'},
  fillBar: {height: 4, backgroundColor: Palette.accent},
});
