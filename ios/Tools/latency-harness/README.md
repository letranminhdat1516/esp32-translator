# Latency harness

Measures the conversation pipeline's latency on this Mac with the app's own sources (compiled with `swiftc`
like `../vi-harness`, nothing copied), on synthetic speech fed in real time. Every time is wall clock, per
utterance, from the speech start or end of the phrase on the generated timeline.

```sh
./run.sh            # build, make the audio if missing, run everything (~10 min) into out/<timestamp>/
QUICK=1 ./run.sh    # translate-bench, tts-bench and the app wiring of both directions only
```

`out/<timestamp>/summary.txt` has the p50/p90/max tables and every recognized phrase; `them-*.tsv` and
`you-*.tsv` one row per utterance (`all-them.tsv`, `all-you.tsv`: every variant); `translate.tsv`, `tts.tsv`
the benchmarks; `*.diag.log` the app's `Diag` lines (recognizer lag per result).

Single runs:

```sh
./build.sh && ./make-audio.sh
./latency-harness them audio/en/list.tsv out/them.tsv      # Them → You
./latency-harness you  audio/vi/list.tsv out/you.tsv       # You → Them
./latency-harness translate-bench out/translate.tsv
TTS_MODES=speak,write ./latency-harness tts-bench out/tts.tsv
```

## What runs

| | Wiring (app code in **bold**) |
|---|---|
| Them → You | board VAD (port of `translator_step`, 300 ms pre-roll, 800 ms hangover) → ADPCM encoder (port of `firmware/main/adpcm.c`), 20 ms packets → **ADPCMDecoder** → **EngineMapping.pcm16Buffer** → **BufferConverter** → **LiveTranscriber** (SpeechTranscriber en-US) with **finalizeNow** 0.25 s after packets pause (as `AppleVoiceEngine.feedTheirAudio`) → final phrase → in-order worker: **TextPipeline**(.theirs) over Translator en→vi → TTS vi-VN |
| You → Them | 341-frame float buffers (the mic tap) → **MicSource.handle** (**BufferConverter** → **VoiceGate**) → **LiveTranscriber** (DictationTranscriber vi-VN), **finalizeNow** on gate close → **TurnAssembler** → **SubtitleTranslator**(**TextPipeline**(.mine) over Translator vi→en) → `onResult` = the text sent to the board |

Not the app's code, and why:
- `Speaker.swift` sets `usesApplicationAudioSession` (iOS only), so `TTS.swift` mirrors its utterance setup
  (**EngineMapping.bestVoice**, rate 0.54, no delays, the same volume-0 warm-up).
- `Translator.swift` needs a macOS 26.4 deployment target for `preferredStrategy: .lowLatency`; on an older
  macOS `build.sh` compiles `TranslatorShim.swift` (same class, default strategy). The tables show which ran.
- The board side (VAD, ADPCM encoder) is ported from the firmware in `BoardSim.swift`.

## Audio

`make-audio.sh` makes 12 phrases per direction with `say` (Samantha en-US, Linh vi-VN; 16 kHz 16-bit):
hotel, taxi, doctor, shop, and two long sentences each. The harness trims each clip to its speech (energy:
10 ms frames above max(-50 dBFS, peak - 40 dB)), lays them out with 1.5 s of silence between them, and adds
white noise at -65 dBFS (`NOISE_DB`, `off` for digital silence) so the gates see a background.

## Metrics

- `t_first_volatile`: speech start → first non-empty volatile result.
- `t_final first/last phrase`: speech end → first/last final phrase of the utterance (finals are matched to
  utterances by shared words among the last three started).
- `finalizeNow call`, `finalizeNow → final`, `gate close`, `gate close → final`: where the finalization comes from.
- `t_translate`: final text → translated text (the TextPipeline call); COLD = the first call of a fresh
  Translator, made lazily on the first phrase as the app does.
- `volatile update → its subtitle`: `SubtitleTranslator.setPartial` → translation done, for volatile phrases
  whose subtitle was shown (not superseded/dropped).
- `t_tts_first_audio`: speak → `didStart` (TTS=speak) or write → first PCM buffer (TTS=write).
- E2E Them → You: speech end → first TTS audio of the utterance's last phrase. E2E You → Them: speech end →
  subtitle update carrying the translation of the utterance's last final phrase.

## Variables

`them`: `ADPCM=0` raw PCM; `STREAM=continuous` the board streams everything (no pause finalize unless
`FINALIZE=1`); `FINALIZE=0` no finalizeNow on the packet pause; `TTS=speak|write`; `TTS_VOLUME`; `WARMUP=0`.
`you`: `GATE=0` no gate (continuous audio, no finalizeNow); `FINALIZE=0` gate without finalizeNow.
`VARIANT` labels the TSV rows. `NOISE_DB` for both.

## Experiments

`./experiments.sh` (RUNS=2, ONLY=them|you, ~45 min) runs harness-only variants into `out/exp-<timestamp>/`
(`results.tsv`: one RESULT line per run with damage count / WER, splits, final and end-to-end p50/p90):

- Them → You: `PAD=silence|noise` (no finalizeNow; feed silence or comfort noise at the board VAD floor while
  packets pause, so the recognizer ends phrases itself), `REC=exp FINALIZE_AT=last` (finalize through the last
  real audio instead of nil), `REC=exp FAST=0` (no .fastResults), `BOARD_HANGOVER_MS`, `PAUSE_GAP`.
  `REC=exp` is `ExpTranscriber` in `Experiment.swift`, a configurable mirror of LiveTranscriber's session;
  `REC=exp` alone is the control and reproduces the app.
- You → Them: `GATE_HANG` (VoiceGate hangover), `EARLY_FINALIZE=<s>` (finalizeNow when a shadow gate with that
  hangover closes; the real gate still decides what is fed).

Damaged = a run of punctuation in place of words (`,....`) or WER > 0.3 against the script (numbers normalized).

## Caveats

- Mac (M-series, macOS 26.3) not iPhone: the recognizers and translator run on a faster chip with more memory;
  expect the model-bound stages (recognition lag, translation) to be slower on the phone. Structural delays
  (gate/VAD hangovers, the 0.25 s pause timer, finalization waits) carry over unchanged.
- Without macOS 26.4 the translator runs without `.lowLatency`.
- Synthetic voices are clean and evenly paced; real speech, AirPods/board mics and noise change recognition
  timing and the gate's behaviour. The first utterance is also where the VoiceGate learns the wearer's level.
- `didStart` on the Mac fires when synthesis starts, not when sound leaves the AirPods: Bluetooth output
  adds roughly 150–250 ms on the iPhone that no number here includes. BLE transport (board → phone, phone →
  board) is not included either.
- Only the compact vi-VN voice (Linh) is installed here; an enhanced/premium voice loads more slowly.
- With 12 utterances per run, p90 is close to the second-worst value.
