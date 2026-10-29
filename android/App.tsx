/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 */

import { useState } from 'react';
import { NewAppScreen } from '@react-native/new-app-screen';
import {
  Pressable,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';
import { EngineProbe } from './src/dev/EngineProbe';

function App() {
  const isDarkMode = useColorScheme() === 'dark';

  return (
    <SafeAreaProvider>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <AppContent />
    </SafeAreaProvider>
  );
}

function AppContent() {
  const safeAreaInsets = useSafeAreaInsets();
  // Dev screen of the voice engine (T4), opened with the "dev" button
  const [dev, setDev] = useState(false);

  if (dev) {
    return <EngineProbe onClose={() => setDev(false)} />;
  }
  return (
    <View style={styles.container}>
      <NewAppScreen
        templateFileName="App.tsx"
        safeAreaInsets={safeAreaInsets}
      />
      <Pressable
        accessibilityRole="button"
        onPress={() => setDev(true)}
        style={[styles.dev, { top: safeAreaInsets.top + 8 }]}
      >
        <Text style={styles.devText}>dev</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  dev: {
    position: 'absolute',
    right: 16,
    backgroundColor: '#1E6FD9',
    borderRadius: 8,
    paddingVertical: 6,
    paddingHorizontal: 12,
  },
  devText: {
    color: '#E3EAF0',
    fontSize: 14,
  },
});

export default App;
