#!/bin/zsh
# Builds, generates the test audio if missing, and runs every measurement into out/<timestamp>/:
# translate-bench, tts-bench, Them → You (app wiring + diagnostic variants), You → Them (app + variants).
# Each run takes about a minute (real-time audio). TTS_VOLUME sets the playback volume of the spoken
# translations (default 0.3; TTS=write synthesizes without playing). QUICK=1 runs only the app wiring.
set -e
here=${0:A:h}
$here/build.sh
[[ -f $here/audio/en/list.tsv && -f $here/audio/vi/list.tsv ]] || $here/make-audio.sh
out=$here/out/$(date +%Y%m%d-%H%M%S)
mkdir -p $out
h=$here/latency-harness
export TTS_VOLUME=${TTS_VOLUME:-0.3}
run() {  # name, env…, args…
  local name=$1; shift
  echo "\n### $name" | tee -a $out/summary.txt
  env "$@" 2>&1 | grep -v '^        ' | tee -a $out/summary.txt
}
run translate-bench $h translate-bench $out/translate.tsv
run tts-bench TTS_MODES=speak,write $h tts-bench $out/tts.tsv
run them-app VARIANT=app $h them $here/audio/en/list.tsv $out/them-app.tsv
run you-app VARIANT=app $h you $here/audio/vi/list.tsv $out/you-app.tsv
if [[ $QUICK != 1 ]]; then
  # Them → You: what finalizeNow on the packet pause does (the board's VAD gaps alone vs the finalize call)
  run them-vad-nofinalize VARIANT=vad-nofinalize FINALIZE=0 TTS=write $h them $here/audio/en/list.tsv $out/them-vad-nofinalize.tsv
  run them-continuous VARIANT=continuous STREAM=continuous TTS=write $h them $here/audio/en/list.tsv $out/them-continuous.tsv
  run them-continuous-finalize VARIANT=continuous-finalize STREAM=continuous FINALIZE=1 TTS=write $h them $here/audio/en/list.tsv $out/them-continuous-finalize.tsv
  run them-rawpcm VARIANT=rawpcm ADPCM=0 TTS=write $h them $here/audio/en/list.tsv $out/them-rawpcm.tsv
  # You → Them: the gate without finalizeNow, and no gate at all
  run you-gate-nofinalize VARIANT=gate-nofinalize FINALIZE=0 $h you $here/audio/vi/list.tsv $out/you-gate-nofinalize.tsv
  run you-nogate VARIANT=nogate GATE=0 $h you $here/audio/vi/list.tsv $out/you-nogate.tsv
fi
# One TSV with every utterance row of every direction and variant
{ head -1 $out/them-app.tsv; for f in $out/them-*.tsv; do tail -n +2 $f; done } > $out/all-them.tsv
{ head -1 $out/you-app.tsv; for f in $out/you-*.tsv; do tail -n +2 $f; done } > $out/all-you.tsv
echo "\nresults in $out (summary.txt, *.tsv; the app's Diag lines in *.diag.log)"
