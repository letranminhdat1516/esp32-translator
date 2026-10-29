// Port of app/lib/ui/conversation_screen.dart ("Phụ đề"; ios/Sources/UI/ContentView.swift):
// header (language pair, settings, status line with chips), the stream of lines, the control bar.
import React, {useMemo, useRef, useState} from 'react';
import {ActivityIndicator, Modal, Pressable, ScrollView, StyleSheet, View} from 'react-native';
import {Chip, PrimaryButton, TextButton, Txt} from './components';
import {t} from './copy';
import {ReadinessView} from './ReadinessView';
import {Layout, Palette, Spacing, Type} from './theme';
import {UiIntents, UiLine, UiState, hasHistory} from './uiState';

export interface ConversationScreenProps {
  state: UiState;
  intents: UiIntents;
  /** Opens the language sheet (navigation, not an engine intent). */
  onOpenLanguages: () => void;
  onOpenGlossary: () => void;
}

export function ConversationScreen({state, intents, onOpenLanguages, onOpenGlossary}: ConversationScreenProps) {
  const [confirmClear, setConfirmClear] = useState(false);
  const canClear = state.phase === 'running' && hasHistory(state);
  // The trash sits next to the listen button: a stray tap must not wipe the conversation.
  const askClear = () => setConfirmClear(true);

  let body: React.ReactNode;
  switch (state.phase) {
    case 'needsDownload':
      body =
        state.session === null ? (
          <View style={styles.centerFill}>
            <ActivityIndicator testID="spinner" color={Palette.muted} />
          </View>
        ) : (
          <ReadinessView
            state={state.session}
            onDownload={intents.onDownload}
            onRetry={intents.onRetry}
            offered={state.offeredPacks}
            onlineCodes={state.onlineCodes}
            onPick={intents.pickLanguage}
            labels={state.languageNames}
            progress={state.downloadProgress}
          />
        );
      break;
    case 'preparing':
      body = (
        <View style={styles.centerFill}>
          <ActivityIndicator testID="spinner" color={Palette.muted} />
          <Txt style={styles.preparing}>{state.message}</Txt>
        </View>
      );
      break;
    case 'failed':
      body = (
        <View style={styles.centerFill}>
          <Txt style={styles.warnIcon}>⚠</Txt>
          <Txt style={styles.failedTitle}>{t('failed.title')}</Txt>
          <Txt style={styles.failedReason}>{state.message}</Txt>
          <PrimaryButton text={t('failed.retry')} onPress={intents.onRetry} style={styles.retry} />
        </View>
      );
      break;
    case 'idle':
    case 'running':
      body = (
        <View style={styles.fill}>
          <ConversationView state={state} />
          <ControlBar state={state} intents={intents} canClear={canClear} onClear={askClear} />
        </View>
      );
      break;
  }

  return (
    <View style={styles.screen}>
      <Header
        state={state}
        canClear={canClear}
        onClear={askClear}
        onOpenLanguages={onOpenLanguages}
        onOpenGlossary={onOpenGlossary}
      />
      {state.ttsVoiceMissing ? <TtsBanner onOpen={intents.openTtsSettings} /> : null}
      {body}
      <Modal
        visible={confirmClear}
        transparent
        statusBarTranslucent
        animationType="fade"
        onRequestClose={() => setConfirmClear(false)}>
        <View style={styles.dialogBackdrop}>
          <View style={styles.dialog}>
            <Txt style={styles.dialogTitle}>{t('dialog.clearTitle')}</Txt>
            <View style={styles.dialogActions}>
              <TextButton text={t('dialog.cancel')} onPress={() => setConfirmClear(false)} />
              <TextButton
                text={t('dialog.clearConfirm')}
                color={Palette.destructive}
                onPress={() => {
                  setConfirmClear(false);
                  intents.clearHistory();
                }}
              />
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

function TtsBanner({onOpen}: {onOpen: () => void}) {
  return (
    <View style={styles.banner}>
      <Txt style={styles.bannerText}>{t('banner.text')}</Txt>
      <TextButton text={t('banner.open')} onPress={onOpen} />
    </View>
  );
}

function boardText(state: UiState): string {
  switch (state.board) {
    case 'off':
      return t('board.off');
    case 'scanning':
      return t('board.scanning');
    case 'connecting':
      return t('board.connecting');
    case 'ready':
      return state.boardMicOn ? t('board.ready') : t('board.readyMicOff');
  }
}

/** Language pair, settings, and one status line: listening, board, chips. */
function Header({
  state,
  canClear,
  onClear,
  onOpenLanguages,
  onOpenGlossary,
}: {
  state: UiState;
  canClear: boolean;
  onClear: () => void;
  onOpenLanguages: () => void;
  onOpenGlossary: () => void;
}) {
  const [menu, setMenu] = useState(false);
  const listening = state.listening;
  const choose = (f: () => void) => () => {
    setMenu(false);
    f();
  };
  return (
    <View style={styles.header}>
      <View style={styles.headerRow}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('header.pair', {label: state.languageLabel})}
          onPress={onOpenLanguages}
          style={styles.pill}>
          <Txt style={styles.pillText}>{t('header.home')}</Txt>
          <Txt style={styles.swap}>⇄</Txt>
          <Txt style={styles.pillText}>{state.languageLabel}</Txt>
        </Pressable>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('settings.label')}
          onPress={() => setMenu(m => !m)}
          style={styles.settings}>
          <Txt style={styles.settingsIcon}>⋮</Txt>
        </Pressable>
      </View>
      {menu ? (
        <View style={styles.menu}>
          <MenuRow text={t('menu.languages')} onPress={choose(onOpenLanguages)} />
          <MenuRow text={t('menu.glossary')} onPress={choose(onOpenGlossary)} />
          <MenuRow
            text={t('menu.clear')}
            disabled={!canClear}
            color={canClear ? Palette.destructive : Palette.faint}
            onPress={choose(onClear)}
          />
        </View>
      ) : null}
      <View style={styles.status}>
        <View style={styles.statusLeft}>
          <View style={[styles.dot, {backgroundColor: listening ? Palette.accentLight : Palette.faint}]} />
          <Txt style={[styles.statusText, {color: listening ? Palette.text : Palette.muted}]}>
            {listening ? t('status.listening') : t('status.waiting')}
          </Txt>
        </View>
        <Txt style={styles.boardText}>{`· ${boardText(state)}`}</Txt>
        {state.onlineRecognizer ? (
          <Chip text={t('chip.online')} accessibilityText={t('chip.online.a11y')} />
        ) : null}
        {listening && state.micRoute === 'phoneMic' ? (
          <Chip text={t('chip.phoneMic')} accessibilityText={t('chip.phoneMic.a11y')} />
        ) : null}
        {listening && state.board !== 'ready' ? (
          <Chip text={t('chip.noBoard')} accessibilityText={t('chip.noBoard.a11y')} />
        ) : null}
      </View>
    </View>
  );
}

function MenuRow({
  text,
  onPress,
  disabled = false,
  color = Palette.text,
}: {
  text: string;
  onPress: () => void;
  disabled?: boolean;
  color?: string;
}) {
  return (
    <Pressable
      accessibilityRole="menuitem"
      accessibilityState={{disabled}}
      disabled={disabled}
      onPress={onPress}
      style={styles.menuRow}>
      <Txt style={{fontSize: Type.body, color}}>{text}</Txt>
    </Pressable>
  );
}

interface Entry {
  line: UiLine;
  mine: boolean;
}

/** Both sides in one stream, oldest first (ties by id): theirs on the left, mine on the right. */
export function entriesOf(s: UiState): Entry[] {
  const all: Entry[] = [
    ...s.theirLines.map(line => ({line, mine: false})),
    ...s.myLines.filter(l => l.source.length > 0).map(line => ({line, mine: true})),
  ];
  return all.sort((a, b) =>
    a.line.at !== b.line.at ? a.line.at - b.line.at : a.line.id < b.line.id ? -1 : a.line.id > b.line.id ? 1 : 0,
  );
}

function ConversationView({state}: {state: UiState}) {
  const scroll = useRef<React.ComponentRef<typeof ScrollView>>(null);
  const entries = useMemo(() => entriesOf(state), [state]);
  const empty = entries.length === 0 && state.theirPartial === '' && state.myPartial === '';
  return (
    <ScrollView
      ref={r => {
        scroll.current = r;
      }}
      style={styles.fill}
      contentContainerStyle={styles.lines}
      // Autoscroll to the end whenever a line or a partial changes the content height.
      onContentSizeChange={() => scroll.current?.scrollToEnd({animated: true})}>
      {empty ? <EmptyHint listening={state.listening} /> : null}
      {entries.map(e => (
        <Bubble
          key={`${e.mine ? 'm' : 't'}:${e.line.id}`}
          label={e.mine ? t('bubble.mine') : t('bubble.theirs')} line={e.line} mine={e.mine} />
      ))}
      {state.theirPartial !== '' ? <PartialLine text={state.theirPartial} mine={false} /> : null}
      {state.myPartial !== '' ? <PartialLine text={state.myPartial} mine /> : null}
    </ScrollView>
  );
}

function Bubble({label, line, mine}: {label: string; line: UiLine; mine: boolean}) {
  const align = mine ? 'flex-end' : 'flex-start';
  const textAlign = mine ? 'right' : 'left';
  return (
    <View style={[styles.bubble, {alignSelf: align, alignItems: align}]}>
      <Txt style={styles.bubbleLabel}>{label}</Txt>
      <Txt style={[styles.bubbleSource, {textAlign}]}>{line.source}</Txt>
      {line.target !== '' ? (
        <Txt
          testID="bubbleTarget"
          style={[styles.bubbleTarget, {textAlign, color: line.unclear ? Palette.faint : Palette.text}]}>
          {line.target}
        </Txt>
      ) : null}
    </View>
  );
}

function PartialLine({text, mine}: {text: string; mine: boolean}) {
  return (
    <View style={[styles.bubble, mine ? styles.selfEnd : styles.selfStart]}>
      <Txt style={[styles.partial, mine ? styles.right : styles.left]}>{text}</Txt>
    </View>
  );
}

function EmptyHint({listening}: {listening: boolean}) {
  return (
    <View style={styles.emptyHint}>
      <Txt style={styles.emptyTitle}>{listening ? t('hint.listening') : t('hint.idle')}</Txt>
      <Txt style={styles.emptyBody}>{t('hint.body')}</Txt>
    </View>
  );
}

/** Board mic · listen / stop · clear */
function ControlBar({
  state,
  intents,
  canClear,
  onClear,
}: {
  state: UiState;
  intents: UiIntents;
  canClear: boolean;
  onClear: () => void;
}) {
  const micOn = state.boardMicOn;
  const running = state.phase === 'running';
  const listening = state.listening;
  const micEnabled = state.board === 'ready';
  return (
    <View style={styles.controls}>
      <RoundButton
        icon={micOn ? '🎤' : '🔇'}
        label={micOn ? t('control.micOff') : t('control.micOn')}
        ring={micOn}
        enabled={micEnabled}
        onPress={intents.toggleBoardMic}
      />
      <Pressable
        testID="listenButton"
        accessibilityRole="button"
        accessibilityLabel={listening ? t('control.stop') : t('control.start')}
        accessibilityState={{disabled: !running}}
        disabled={!running}
        onPress={listening ? intents.stopListening : intents.startListening}
        style={[
          styles.listen,
          listening ? styles.listenOn : styles.listenOff,
          !running && styles.dim,
        ]}>
        {/* The header already says "Đang nghe": the button says what a tap does. */}
        <Txt style={styles.listenIcon}>{listening ? '■' : '●'}</Txt>
        <Txt style={styles.listenText}>{listening ? t('control.stop') : t('control.start')}</Txt>
      </Pressable>
      <RoundButton icon="🗑" label={t('control.clear')} enabled={canClear} onPress={onClear} />
    </View>
  );
}

function RoundButton({
  icon,
  label,
  enabled,
  onPress,
  ring = false,
}: {
  icon: string;
  label: string;
  enabled: boolean;
  onPress: () => void;
  ring?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{disabled: !enabled}}
      disabled={!enabled}
      onPress={onPress}
      style={[styles.round, ring && styles.roundRing, !enabled && styles.dim]}>
      <Txt style={styles.roundIcon}>{icon}</Txt>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: Palette.ground},
  fill: {flex: 1},
  centerFill: {flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: Spacing.xxl},
  preparing: {color: Palette.muted, fontSize: Type.body, marginTop: Spacing.l},
  warnIcon: {fontSize: 40, color: Palette.muted},
  failedTitle: {fontSize: Type.line, marginTop: Spacing.m},
  failedReason: {fontSize: Type.body, color: Palette.muted, textAlign: 'center', marginTop: Spacing.s},
  retry: {marginTop: Spacing.l, paddingHorizontal: 24, paddingVertical: 12},
  // header
  header: {paddingHorizontal: Spacing.xl, paddingTop: Spacing.s, paddingBottom: Spacing.m},
  headerRow: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  pill: {
    height: Layout.pillHeight,
    paddingHorizontal: 14,
    borderRadius: 999,
    backgroundColor: Palette.surface,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.s,
  },
  pillText: {fontSize: Type.body},
  swap: {fontSize: 18, color: Palette.muted},
  settings: {
    width: Layout.settingsButton,
    height: Layout.settingsButton,
    borderRadius: Layout.settingsButton / 2,
    backgroundColor: Palette.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  settingsIcon: {fontSize: 20, color: Palette.muted},
  menu: {
    alignSelf: 'flex-end',
    marginTop: Spacing.xs,
    backgroundColor: Palette.surface,
    borderRadius: 14,
    paddingVertical: Spacing.xs,
    minWidth: 200,
  },
  menuRow: {paddingHorizontal: Spacing.l, paddingVertical: 12},
  status: {flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: Spacing.s, marginTop: Spacing.m},
  statusLeft: {flexDirection: 'row', alignItems: 'center', gap: Spacing.s},
  dot: {width: 8, height: 8, borderRadius: 4},
  statusText: {fontSize: Type.small},
  boardText: {fontSize: Type.small, color: Palette.muted},
  // banner
  banner: {
    marginHorizontal: Spacing.xl,
    marginBottom: Spacing.s,
    padding: Spacing.m,
    borderRadius: 14,
    backgroundColor: Palette.surface,
  },
  bannerText: {fontSize: Type.secondary, color: Palette.muted},
  // lines
  lines: {paddingHorizontal: Spacing.xl, paddingVertical: Spacing.s, gap: Spacing.line},
  bubble: {maxWidth: Layout.bubbleMaxWidth},
  bubbleLabel: {fontSize: Type.caption, color: Palette.muted},
  bubbleSource: {fontSize: Type.secondary, color: Palette.muted, marginTop: Spacing.xs},
  bubbleTarget: {fontSize: Type.line, marginTop: Spacing.xs},
  partial: {fontSize: Type.secondary, fontStyle: 'italic', color: Palette.faint},
  emptyHint: {paddingTop: 120, paddingHorizontal: Spacing.m, alignItems: 'center'},
  emptyTitle: {fontSize: Type.row, textAlign: 'center'},
  emptyBody: {fontSize: Type.secondary, color: Palette.muted, textAlign: 'center', marginTop: Spacing.s},
  // controls
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.xl,
    paddingTop: Spacing.m,
    paddingBottom: Spacing.s,
  },
  round: {
    width: Layout.roundButton,
    height: Layout.roundButton,
    borderRadius: Layout.roundButton / 2,
    backgroundColor: Palette.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  roundRing: {borderWidth: 2, borderColor: Palette.accent},
  roundIcon: {fontSize: 20, color: Palette.text},
  listen: {
    height: Layout.listenHeight,
    paddingHorizontal: 28,
    borderRadius: 999,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.s,
  },
  listenIcon: {fontSize: 16, color: Palette.white},
  listenText: {fontSize: Type.button, color: Palette.white},
  selfStart: {alignSelf: 'flex-start'},
  selfEnd: {alignSelf: 'flex-end'},
  left: {textAlign: 'left'},
  right: {textAlign: 'right'},
  dim: {opacity: 0.4},
  listenOn: {backgroundColor: Palette.accent},
  listenOff: {backgroundColor: Palette.surface},
  // dialog
  dialogBackdrop: {flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'center', padding: Spacing.xxl},
  dialog: {backgroundColor: Palette.surface, borderRadius: 16, padding: Spacing.xl},
  dialogTitle: {fontSize: Type.row},
  dialogActions: {flexDirection: 'row', justifyContent: 'flex-end', marginTop: Spacing.l},
});
