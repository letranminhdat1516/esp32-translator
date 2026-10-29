/**
 * Root of the app. Wires the "Phụ đề" screens to a UI state and intents.
 *
 * Production: P2.1 passes `intents` (the controller) and `initialState`, and keeps the `update`
 * of `useUiState` for engine events; `intents` is required then (App throws without it).
 * Development (`__DEV__`) without `intents`: sample intents that only change the sample state, so
 * the screens can be tried by hand; a console warning says so.
 *
 * The picked language is saved on every pick and loaded on mount (src/ui/pickStorage.ts).
 *
 * @format
 */

import React, {useEffect, useMemo, useState} from 'react';
import {StatusBar, StyleSheet, View} from 'react-native';
import {SafeAreaProvider, useSafeAreaInsets} from 'react-native-safe-area-context';
import {t} from './src/ui/copy';
import {ConversationScreen} from './src/ui/ConversationScreen';
import {GlossaryScreen} from './src/ui/GlossaryScreen';
import {LanguageSheet} from './src/ui/LanguageSheet';
import {loadPickedLanguage, savePickedLanguage} from './src/ui/pickStorage';
import {Palette} from './src/ui/theme';
import {UiIntents, UiState, emptyUiState, useUiState} from './src/ui/uiState';

/** Empty conversation, ready to listen (what the app shows in development without a controller). */
export const sampleState: UiState = {
  ...emptyUiState,
  phase: 'running',
  languageLabel: 'English',
  currentCode: 'en',
  languageNames: {vi: t('header.home'), en: 'English'},
};

export interface AppProps {
  initialState?: UiState;
  /** Intents of the controller. Required outside development. */
  intents?: UiIntents;
}

function App({initialState = sampleState, intents}: AppProps) {
  if (!__DEV__ && !intents) {
    throw new Error('App needs the controller intents outside development');
  }
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="light-content" />
      <AppContent initialState={initialState} intents={intents} />
    </SafeAreaProvider>
  );
}

function AppContent({
  initialState,
  intents: given,
}: Required<Pick<AppProps, 'initialState'>> & Pick<AppProps, 'intents'>) {
  const insets = useSafeAreaInsets();
  const {state, update} = useUiState(initialState);
  const [sheet, setSheet] = useState(false);
  const [glossary, setGlossary] = useState(false);

  useEffect(() => {
    if (!given) {
      console.warn('App: no intents given, running with the sample intents (development only)');
    }
  }, [given]);

  useEffect(() => {
    let alive = true;
    loadPickedLanguage().then(code => {
      if (alive && code !== null) {
        update({currentCode: code});
      }
    });
    return () => {
      alive = false;
    };
  }, [update]);

  const intents = useMemo<UiIntents>(() => {
    const base: UiIntents = given ?? {
      toggleBoardMic: () => update(s => ({boardMicOn: !s.boardMicOn})),
      startListening: () => update({listening: true}),
      stopListening: () => update({listening: false}),
      clearHistory: () => update({theirLines: [], myLines: [], theirPartial: '', myPartial: ''}),
      onDownload: () => {},
      onRetry: () => {},
      pickLanguage: code => update({currentCode: code}),
      setOnlineAllowed: (code, on) =>
        update(s => ({
          onlineAllowed: on
            ? [...s.onlineAllowed.filter(c => c !== code), code]
            : s.onlineAllowed.filter(c => c !== code),
        })),
      openTtsSettings: () => {},
      addTerm: () => {},
      updateTerm: () => {},
      deleteTerm: () => {},
    };
    return {
      ...base,
      pickLanguage: code => {
        savePickedLanguage(code);
        base.pickLanguage(code);
      },
    };
  }, [given, update]);

  return (
    <View style={[styles.container, {paddingTop: insets.top, paddingBottom: insets.bottom}]}>
      {glossary ? (
        <GlossaryScreen
          terms={state.glossaryTerms}
          onBack={() => setGlossary(false)}
          onAdd={intents.addTerm}
          onUpdate={intents.updateTerm}
          onDelete={intents.deleteTerm}
        />
      ) : (
        <ConversationScreen
          state={state}
          intents={intents}
          onOpenLanguages={() => setSheet(true)}
          onOpenGlossary={() => setGlossary(true)}
        />
      )}
      <LanguageSheet
        visible={sheet}
        packs={state.offeredPacks}
        currentCode={state.currentCode}
        onlineCodes={state.onlineCodes}
        onlineCandidates={state.onlineCandidates}
        onlineAllowed={state.onlineAllowed}
        onSetOnlineAllowed={intents.setOnlineAllowed}
        onClose={() => setSheet(false)}
        onPick={intents.pickLanguage}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: Palette.ground},
});

export default App;
