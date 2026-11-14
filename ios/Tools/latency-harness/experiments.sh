#!/bin/zsh
# Follow-up experiments (harness-only variants): what to do instead of finalize(through: nil) for Them → You,
# and shorter VoiceGate hangovers for You → Them. RUNS (default 2) runs per variant; ONLY=them|you.
# One RESULT line per run in out/exp-<timestamp>/results.tsv; full tables in summary.txt.
set -e
here=${0:A:h}
$here/build.sh
[[ -f $here/audio/en/list.tsv && -f $here/audio/vi/list.tsv ]] || $here/make-audio.sh
out=$here/out/exp-$(date +%Y%m%d-%H%M%S)
mkdir -p $out
h=$here/latency-harness
runs=${RUNS:-2}
export TTS=write
v() {  # name dir env…
  local name=$1 dir=$2; shift 2
  local list=$here/audio/en/list.tsv; [[ $dir == you ]] && list=$here/audio/vi/list.tsv
  for r in $(seq 1 $runs); do
    echo "\n### $name run $r" >> $out/summary.txt
    env VARIANT=$name "$@" $h $dir $list $out/$name-$r.tsv 2>&1 | grep -v '^        ' >> $out/summary.txt
    grep "^RESULT" $out/summary.txt | tail -1 | tee -a $out/results.tsv
  done
}
if [[ $ONLY != you ]]; then
  v them-app them
  v them-exp-control them REC=exp
  v A-silence them FINALIZE=0 PAD=silence
  v A-noise them FINALIZE=0 PAD=noise
  v B-last them REC=exp FINALIZE_AT=last
  v D-nofast them REC=exp FAST=0
  v C-A-silence-400 them FINALIZE=0 PAD=silence BOARD_HANGOVER_MS=400
  v C-A-silence-250 them FINALIZE=0 PAD=silence BOARD_HANGOVER_MS=250
  v C-A-noise-400 them FINALIZE=0 PAD=noise BOARD_HANGOVER_MS=400
  v C-A-noise-250 them FINALIZE=0 PAD=noise BOARD_HANGOVER_MS=250
  v C-B-last-400 them REC=exp FINALIZE_AT=last BOARD_HANGOVER_MS=400
  v C-B-last-250 them REC=exp FINALIZE_AT=last BOARD_HANGOVER_MS=250
fi
if [[ $ONLY != them ]]; then
  v you-app you
  v you-hang-0.5 you GATE_HANG=0.5
  v you-hang-0.4 you GATE_HANG=0.4
  v you-early-0.4 you EARLY_FINALIZE=0.4
fi
echo "results in $out"
