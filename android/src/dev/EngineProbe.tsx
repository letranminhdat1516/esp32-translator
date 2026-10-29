// Dev screen for the Kotlin voice engine (T4): asks capabilities('vi'), downloads what the vi↔en pair
// is missing, starts a session, and shows the engine's events live. It also measures what one 20 ms
// packet of board PCM costs to cross JS → native as base64 (ARCHITECTURE.md R3). Reached from App.tsx
// ("dev"); kept for device debugging.
import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Pressable, ScrollView, StyleSheet, Text, View} from 'react-native';
import {NativeVoiceEngineAdapter} from '../engine/NativeVoiceEngine';
import {PairMsg, VoiceEngine, pcm16leBase64} from '../engine/VoiceEngine';

// The pair the probe exercises: home Vietnamese (always, R20), English on the other side.
const HOME = 'vi';
const OTHER = 'en';
const PAIR: PairMsg = {home: HOME, other: OTHER, generation: 1};
/** 20 ms of 16 kHz mono PCM: one board packet. */
const SAMPLE_RATE = 16000;
const PACKET_SAMPLES = 320;

type Log = (line: string) => void;

/** capabilities(home) → missing(pair) → download each → start with the best `other` recognizer → mic on. */
export async function probeSession(engine: VoiceEngine, log: Log): Promise<void> {
  const caps = await engine.capabilities(HOME);
  const kinds = Object.entries(caps.recognizers).map(([lang, k]) => `${lang}=[${k.join(',')}]`);
  log(`capabilities(${HOME}): ${kinds.join(' ')}; translatable ${caps.translatable.size}; voice ${caps.vietnameseVoice}`);
  const missing = await engine.missing(PAIR);
  log(`missing ${HOME}↔${OTHER}: ${missing.map(m => `${m.kind} ${m.language}`).join(', ') || 'none'}`);
  for (const item of missing) {
    log(`download ${item.kind} ${item.language}…`);
    await engine.downloadItem(item);
    log(`downloaded ${item.kind} ${item.language}`);
  }
  const recognizerX = caps.recognizers[OTHER]?.[0] ?? 'whisper';
  await engine.start(PAIR, recognizerX, []);
  log(`started ${HOME}↔${OTHER} gen ${PAIR.generation} with ${recognizerX}`);
  await engine.micOn(true);
  log('mic on');
}

export interface FeedCost {
  packets: number;
  /** Mean time of one `feedTheirAudio` call (base64 encode + bridge + native decode + promise). */
  msPerPacket: number;
  /** Mean time of the base64 encode alone. */
  encodeMsPerPacket: number;
}

/** Feeds `packets` 20 ms packets (a quiet 440 Hz tone) one after another and times them. */
export async function measureFeed(
  engine: VoiceEngine,
  packets: number,
  now: () => number = () => performance.now(),
): Promise<FeedCost> {
  const pcm = new Int16Array(PACKET_SAMPLES);
  for (let i = 0; i < pcm.length; i++) {
    pcm[i] = Math.round(1000 * Math.sin((2 * Math.PI * 440 * i) / SAMPLE_RATE));
  }
  let feed = 0;
  let encode = 0;
  for (let i = 0; i < packets; i++) {
    const t0 = now();
    pcm16leBase64(pcm);
    const t1 = now();
    await engine.feedTheirAudio(pcm, SAMPLE_RATE);
    const t2 = now();
    encode += t1 - t0;
    // The call encodes the packet itself: this is the whole JS → native cost
    feed += t2 - t1;
  }
  return {packets, msPerPacket: feed / packets, encodeMsPerPacket: encode / packets};
}

function stamp(): string {
  return new Date().toISOString().slice(11, 23);
}

type OwnedEngine = VoiceEngine & {dispose(): void};

export interface EngineProbeProps {
  /** An engine owned by the caller (tests); otherwise the probe creates one and disposes it on unmount. */
  engine?: VoiceEngine;
  createEngine?: () => OwnedEngine;
  onClose?: () => void;
}

export function EngineProbe({
  engine: given,
  createEngine = () => new NativeVoiceEngineAdapter(),
  onClose,
}: EngineProbeProps) {
  const [engine, owned] = useMemo<[VoiceEngine, OwnedEngine | null]>(() => {
    if (given) {
      return [given, null];
    }
    const created = createEngine();
    return [created, created];
    // createEngine is read once: a new function on every render must not rebuild the engine
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [given]);
  /** A session this probe started and has not stopped: stopped on unmount. */
  const sessionStarted = useRef(false);
  const [lines, setLines] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const mounted = useRef(true);

  const log = useCallback((line: string) => {
    if (__DEV__) {
      // Debug builds only: event lines carry recognized text (ruling: transcripts logged only in debug)
      console.log(`EngineProbe ${line}`);
    }
    if (mounted.current) {
      setLines(old => [`${stamp()} ${line}`, ...old].slice(0, 200));
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    const subs = [
      engine.on('mine', m => log(`mine ${m.kind}: ${m.text}`)),
      engine.on('theirs', m => log(`theirs: ${m.text}`)),
      engine.on('gate', open => log(`gate: ${open ? 'open' : 'closed'}`)),
      engine.on('download', d =>
        log(`download ${d.item.kind} ${d.item.language} ${Math.round(d.progress * 100)}%${d.done ? ' done' : ''}${d.error ? ` error ${d.error}` : ''}`),
      ),
      engine.on('audioSession', a => log(`audioSession ${a.kind}${a.route ? ` ${a.route}` : ''}`)),
      engine.on('ttsStart', id => log(`ttsStart ${id}`)),
      engine.on('ttsEnd', id => log(`ttsEnd ${id}`)),
    ];
    return () => {
      mounted.current = false;
      subs.forEach(unsubscribe => unsubscribe());
      if (sessionStarted.current) {
        sessionStarted.current = false;
        engine.stop().catch(e => console.warn(`EngineProbe: stop on unmount failed: ${String(e)}`));
      }
      owned?.dispose();
    };
  }, [engine, owned, log]);

  const run = useCallback(
    async (what: string, task: () => Promise<void>) => {
      setBusy(true);
      try {
        await task();
      } catch (e) {
        const err = e as {code?: string; message?: string};
        log(`${what} failed: ${err.code ?? ''} ${err.message ?? String(e)}`);
      } finally {
        if (mounted.current) {
          setBusy(false);
        }
      }
    },
    [log],
  );

  const onStart = () =>
    run('session', async () => {
      // Marked before the call: a start still in flight at unmount is stopped too (stop cancels it)
      sessionStarted.current = true;
      await probeSession(engine, log);
    });
  const onMeasure = () =>
    run('measure', async () => {
      const cost = await measureFeed(engine, 500);
      log(
        `feedTheirAudio: ${cost.msPerPacket.toFixed(3)} ms/packet (base64 encode ${cost.encodeMsPerPacket.toFixed(3)} ms) over ${cost.packets} packets of 20 ms`,
      );
    });
  const onStop = () => run('stop', async () => {
    sessionStarted.current = false;
    await engine.stop();
    log('stopped');
  });

  return (
    <View style={styles.screen}>
      <View style={styles.bar}>
        <Text style={styles.title}>Engine probe</Text>
        {onClose ? <Button label="Đóng" onPress={onClose} /> : null}
      </View>
      <View style={styles.bar}>
        <Button label="Chạy thử" onPress={onStart} disabled={busy} />
        <Button label="Đo PCM" onPress={onMeasure} disabled={busy} />
        <Button label="Dừng" onPress={onStop} />
      </View>
      <ScrollView style={styles.log}>
        {lines.map((line, i) => (
          <Text key={lines.length - i} style={styles.line}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

function Button({label, onPress, disabled}: {label: string; onPress: () => void; disabled?: boolean}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      disabled={disabled}
      style={[styles.button, disabled ? styles.disabled : null]}>
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#000000', paddingTop: 40, paddingHorizontal: 16},
  bar: {flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12},
  title: {color: '#E3EAF0', fontSize: 20, fontWeight: '600', flex: 1},
  button: {backgroundColor: '#1E6FD9', borderRadius: 8, paddingVertical: 10, paddingHorizontal: 14},
  disabled: {backgroundColor: '#16171A'},
  buttonText: {color: '#E3EAF0', fontSize: 15},
  log: {flex: 1, backgroundColor: '#16171A', borderRadius: 8, padding: 8},
  line: {color: '#8A919C', fontSize: 12, fontFamily: 'monospace', marginBottom: 2},
});
