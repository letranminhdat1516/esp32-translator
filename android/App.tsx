/**
 * Root of the app. Wires the "Phụ đề" screens to a UI state and intents.
 *
 * The product (no props, as index.js registers it): builds the real graph once, before the first
 * render (src/app/bootstrap.ts: native engine, BLE board, AsyncStorage, the board glyph lists,
 * permissions), starts the ConversationController and renders its UiState; the controller is the
 * intents. `controller` injects another one (tests).
 *
 * Screens only (`initialState` and/or `intents` given, no `controller`): the state is local
 * (`useUiState`). Outside development `intents` is required then (App throws without it).
 * Development (`__DEV__`) without `intents`: sample intents that only change the sample state, so
 * the screens can be tried by hand; a console warning says so. The picked language is saved on
 * every pick and loaded on mount (src/ui/pickStorage.ts).
 *
 * Development only: a small "dev" button opens the voice engine probe (src/dev/EngineProbe.tsx, T4).
 *
 * @format
 */

import React, {useEffect, useMemo, useState, useSyncExternalStore} from 'react';
import {Pressable, StatusBar, StyleSheet, Text, View} from 'react-native';
import {SafeAreaProvider, useSafeAreaInsets} from 'react-native-safe-area-context';
import {EngineProbe} from './src/dev/EngineProbe';
import type {Unsubscribe} from './src/engine/VoiceEngine';
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

/** What App needs of the ConversationController (src/engine/ConversationController.ts). */
export interface AppController extends UiIntents {
  getState(): UiState;
  subscribe(listener: (state: UiState) => void): Unsubscribe;
  start(): Promise<void>;
  dispose(): void;
}

export interface AppProps {
  initialState?: UiState;
  /** Intents of the screens-only mode. Required outside development. */
  intents?: UiIntents;
  /** The controller to run instead of the real graph (tests). */
  controller?: AppController;
}

function App({initialState, intents, controller}: AppProps) {
  const screensOnly =
    controller === undefined && (initialState !== undefined || intents !== undefined);
  if (screensOnly && !__DEV__ && !intents) {
    throw new Error('App needs the controller intents outside development');
  }
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="light-content" />
      {screensOnly ? (
        <ScreensOnly initialState={initialState ?? sampleState} intents={intents} />
      ) : (
        <Product controller={controller} />
      )}
    </SafeAreaProvider>
  );
}

/** Builds the real graph; required lazily, so the screens-only mode never binds native modules. */
function realController(): AppController {
  const bootstrap = require('./src/app/bootstrap') as typeof import('./src/app/bootstrap');
  return bootstrap.createAppGraph().controller;
}

/** The real app: the controller's state and intents. */
function Product({controller: given}: {controller?: AppController}) {
  // Built once, before the first render (the glyph lists are loaded inside).
  const [controller] = useState<AppController>(() => given ?? realController());
  useEffect(() => {
    controller.start().catch(e => console.error('App: the controller did not start', e));
    return () => controller.dispose();
  }, [controller]);
  const state = useSyncExternalStore(controller.subscribe, controller.getState);
  return <AppContent state={state} intents={controller} />;
}

function ScreensOnly({
  initialState,
  intents: given,
}: Required<Pick<AppProps, 'initialState'>> & Pick<AppProps, 'intents'>) {
  const {state, update} = useUiState(initialState);

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

  return <AppContent state={state} intents={intents} />;
}

function AppContent({state, intents}: {state: UiState; intents: UiIntents}) {
  const insets = useSafeAreaInsets();
  const [sheet, setSheet] = useState(false);
  const [glossary, setGlossary] = useState(false);
  const [probe, setProbe] = useState(false);

  if (__DEV__ && probe) {
    return <EngineProbe onClose={() => setProbe(false)} />;
  }
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
      {__DEV__ ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => setProbe(true)}
          style={[styles.dev, {bottom: insets.bottom + 8}]}>
          <Text style={styles.devText}>dev</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: Palette.ground},
  dev: {position: 'absolute', left: 8, paddingVertical: 4, paddingHorizontal: 8, opacity: 0.6},
  devText: {color: Palette.faint, fontSize: 12},
});

export default App;
