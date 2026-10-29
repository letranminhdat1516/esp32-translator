// The composition root of the real app: the Kotlin voice engine, the board over BLE, AsyncStorage
// for the pick, the glossary and the online consent, the bundled language packs, the board's glyph
// lists, and the Android permissions. App.tsx calls `createAppGraph` once, before its first render.
import {BleManager} from 'react-native-ble-plx';
import {BlePlxAdapter} from '../board/BleAdapter';
import {BleBoardLink} from '../board/BleBoardLink';
import {BoardGlyphSets} from '../core/boardGlyphs';
import {GlossaryStore, asyncStorageKeyValueStore} from '../core/glossary';
import {bundledPacks} from '../core/sharedAssets';
import {ConversationController} from '../engine/ConversationController';
import {NativeVoiceEngineAdapter} from '../engine/NativeVoiceEngine';
import {loadPickedLanguage, savePickedLanguage} from '../ui/pickStorage';
import {androidPermissionGate} from './permissions';

export interface AppGraph {
  readonly controller: ConversationController;
}

/** Builds the real object graph. Loads the board glyph lists first (BoardText needs them). */
export function createAppGraph(): AppGraph {
  const glyphs = BoardGlyphSets.load();
  const kv = asyncStorageKeyValueStore();
  const controller = new ConversationController({
    engine: new NativeVoiceEngineAdapter(),
    board: new BleBoardLink(new BlePlxAdapter(new BleManager())),
    packs: bundledPacks(),
    pickStore: {load: loadPickedLanguage, save: savePickedLanguage},
    openGlossary: () => GlossaryStore.open(kv),
    settings: kv,
    permissions: androidPermissionGate(),
    glyphs,
    platform: 'android',
  });
  return {controller};
}
