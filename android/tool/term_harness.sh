#!/usr/bin/env bash
# Term harness (P2.5, R10) on a real phone with ML Kit. Never on an emulator.
#
#   tool/term_harness.sh                    # every language of shared/fixtures/terms
#   tool/term_harness.sh --lang en,ja       # some
#   tool/term_harness.sh --write-packs      # also write the best shape into shared/languages/<lang>.json
#
# 1. scripts/term-harness.mjs records every text to translate (each corpus line masked with each
#    placeholder shape, plus the plain line for the fallback) with the app's TypeScript TermProtector;
# 2. the requests are pushed to the app's external files dir and TermHarnessTest (-e harness true)
#    translates them with the engine's MlKitTranslator (downloads missing models: network needed once);
# 3. the responses are pulled back and the same script restores, scores and prints the table.
#
# Output in android/android/app/build/term-harness/: requests.tsv, responses.tsv, summary.md (from the
# phone: time per pair), results.md (the table). Env: SERIAL (default: the only adb device).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here/android"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
ADB=(adb ${SERIAL:+-s "$SERIAL"})
PKG=vn.cicca.livetranslator
REMOTE=/sdcard/Android/data/$PKG/files/term-harness
OUT="$here/android/app/build/term-harness"
mkdir -p "$OUT"

lang_args=()
write_packs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) lang_args=(--lang "$2"); shift 2 ;;
    --write-packs) write_packs=(--write-packs); shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

node "$here/scripts/term-harness.mjs" --translator "record:$OUT/requests.tsv" ${lang_args[@]+"${lang_args[@]}"}

[[ -n "${SERIAL:-}" ]] && export ANDROID_SERIAL="$SERIAL"
./gradlew -q --console=plain :app:installDebug :app:installDebugAndroidTest

"${ADB[@]}" shell mkdir -p "$REMOTE"
"${ADB[@]}" shell rm -f "$REMOTE/responses.tsv"
"${ADB[@]}" push "$OUT/requests.tsv" "$REMOTE/requests.tsv" >/dev/null
out=$("${ADB[@]}" shell am instrument -w -r -e harness true -e class $PKG.harness.TermHarnessTest \
  $PKG.test/androidx.test.runner.AndroidJUnitRunner)
if ! echo "$out" | grep -q "^OK ("; then
  echo "$out" | grep -E "stack=|^FAILURES|^Tests run" >&2 || echo "$out" >&2
  exit 1
fi
"${ADB[@]}" pull "$REMOTE/responses.tsv" "$OUT/responses.tsv" >/dev/null
"${ADB[@]}" pull "$REMOTE/summary.md" "$OUT/summary.md" >/dev/null
cat "$OUT/summary.md"
echo
node "$here/scripts/term-harness.mjs" --translator "replay:$OUT/responses.tsv" --out "$OUT/results.md" \
  ${lang_args[@]+"${lang_args[@]}"} ${write_packs[@]+"${write_packs[@]}"}
