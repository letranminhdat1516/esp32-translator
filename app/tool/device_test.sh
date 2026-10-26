#!/usr/bin/env bash
# Run the Android instrumented tests on a real phone without uninstalling the app afterwards
# (Gradle's connectedAndroidTest uninstalls it, which deletes the pushed Whisper model and clips).
#
#   tool/device_test.sh                       # every test
#   tool/device_test.sh WhisperTest           # one class
#   tool/device_test.sh WhisperTest#noiseGivesNothing
#   OFFLINE=1 tool/device_test.sh MlKitTranslatorTest   # airplane-mode test (turn the network off first)
#
# Env: SERIAL (default: the only adb device), WHISPER_MODEL (path to ggml-base-q5_1.bin, pushed if missing).
set -euo pipefail
cd "$(dirname "$0")/../android"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
ADB=(adb ${SERIAL:+-s "$SERIAL"})
PKG=vn.cicca.livetranslator
FILES=/sdcard/Android/data/$PKG/files

./gradlew -q --console=plain :app:installDebug :app:installDebugAndroidTest

# Test fixtures live in the app's external files dir (the phone may have no network)
"${ADB[@]}" shell mkdir -p "$FILES"
have() { "${ADB[@]}" shell "[ -f $FILES/$1 ]" 2>/dev/null; }
if ! have ggml-base-q5_1.bin; then
  if [[ -n "${WHISPER_MODEL:-}" && -f "$WHISPER_MODEL" ]]; then
    "${ADB[@]}" push "$WHISPER_MODEL" "$FILES/ggml-base-q5_1.bin" >/dev/null 2>&1
  else
    echo "note: no Whisper model on the phone; set WHISPER_MODEL to push it (Whisper tests will be skipped)" >&2
  fi
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
clip() { # name voice rate text (the sentences WhisperTest expects)
  have "$1" && return
  say -v "$2" -r "$3" -o "$tmp/$1.aiff" "$4"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/$1.aiff" "$tmp/$1"
  "${ADB[@]}" push "$tmp/$1" "$FILES/$1" >/dev/null 2>&1
}
clip en.wav Samantha 175 "Excuse me, could you tell me where the train station is? I need to get there before noon."
clip vi.wav Linh 210 "Xin lỗi, bạn có thể chỉ cho tôi đường đến ga tàu không?"

args=()
if [[ $# -gt 0 ]]; then
  t=$1
  [[ $t == *.* ]] || t=$PKG.engine.$t
  args+=(-e class "$t")
fi
[[ -n "${OFFLINE:-}" ]] && args+=(-e offline true)
out=$("${ADB[@]}" shell am instrument -w -r ${args[@]+"${args[@]}"} $PKG.test/androidx.test.runner.AndroidJUnitRunner)
echo "$out" | grep -E "^INSTRUMENTATION_STATUS: (class|test|stack)=|INSTRUMENTATION_STATUS_CODE: -[1-4]|^OK|^FAILURES|^Tests run" \
  | awk '/class=/{c=$0; sub(/.*\./,"",c)} /test=/{t=$0; sub(/.*test=/,"",t)} /STATUS_CODE: -2/{print "FAIL " c "." t} /STATUS_CODE: -3/{print "skip " c "." t} /stack=/{print} /^OK|^FAILURES|^Tests run/{print}'
echo "$out" | grep -q "^OK (" 
