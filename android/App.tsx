/**
 * Root of the app. Wires the "Phụ đề" screens to a UI state and intents. Until P2.1 binds the real
 * controller the state is the empty/sample state below and the intents only change that state, so
 * the app boots and the screens can be tried by hand. P2.1 passes `initialState` and `intents`
 * (and keeps the `update` of `useUiState` for engine events) instead.
 *
 * @format
 */

import React, {useMemo, useState} from 'react';
import {StatusBar, StyleSheet, View} from 'react-native';
import {SafeAreaProvider, useSafeAreaInsets} from 'react-native-safe-area-context';
import {ConversationScreen} from './src/ui/ConversationScreen';
import {GlossaryScreen} from './src/ui/GlossaryScreen';
import {LanguageSheet} from './src/ui/LanguageSheet';
import {savePickedLanguage} from './src/ui/pickStorage';
import {Palette} from './src/ui/theme';
import {UiIntents, UiState, emptyUiState, useUiState} from './src/ui/uiState';

/** Empty conversation, no board, ready to listen (what the app shows until a controller binds). */
export const sampleState: UiState = {
  ...emptyUiState,
  phase: 'running',
  noBoard: true,
  languageLabel: 'English',
  currentCode: 'en',
  languageNames: {vi: 'Tiếng Việt', en: 'English'},
};

export interface AppProps {
  initialState?: UiState;
  /** Intents of the controller; the defaults only change the sample state. */
  intents?: UiIntents;
}

function App({initialState = sampleState, intents}: AppProps) {
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="light-content" />
      <AppContent initialState={initialState} intents={intents} />
    </SafeAreaProvider>
  );
}

function AppContent({initialState, intents: given}: Required<Pick<AppProps, 'initialState'>> & Pick<AppProps, 'intents'>) {
  const insets = useSafeAreaInsets();
  const {state, update} = useUiState(initialState);
  const [sheet, setSheet] = useState(false);
  const [glossary, setGlossary] = useState(false);

  const intents = useMemo<UiIntents>(
    () =>
      given ?? {
        toggleBoardMic: () => update(s => ({boardMicOn: !s.boardMicOn})),
        startListening: () => update({listening: true}),
        stopListening: () => update({listening: false}),
        clearHistory: () => update({theirLines: [], myLines: [], theirPartial: '', myPartial: ''}),
        onDownload: () => {},
        onRetry: () => {},
        pickLanguage: code => {
          update({currentCode: code});
          savePickedLanguage(code);
        },
        setOnlineOptIn: on => update({onlineOptIn: on}),
        openTtsSettings: () => {},
        addTerm: () => {},
        updateTerm: () => {},
        deleteTerm: () => {},
      },
    [given, update],
  );

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
        marks={state.languageMarks}
        onlineOptIn={state.onlineOptIn}
        onSetOnlineOptIn={intents.setOnlineOptIn}
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
