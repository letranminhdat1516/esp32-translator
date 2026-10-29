#!/usr/bin/env bash
# Run the engine's instrumented tests on a real phone without uninstalling the app afterwards
# (Gradle's connectedAndroidTest uninstalls it, which deletes the pushed Whisper model and clips).
# Port of app/tool/device_test.sh for the React Native app. Never on an emulator.
#
#   tool/device_test.sh                       # every test
#   tool/device_test.sh WhisperTest           # one class
#   tool/device_test.sh WhisperTest#noiseGivesNothing
#   OFFLINE=1 tool/device_test.sh MlKitTranslatorTest   # airplane-mode test (turn the network off first)
#
# Env: SERIAL (default: the only adb device), WHISPER_MODEL (path to ggml-base-q5_1.bin, pushed if the
# phone has none; default: the copy in the build session's scratchpad, when present).
set -euo pipefail
cd "$(dirname "$0")/../android"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
WHISPER_MODEL="${WHISPER_MODEL:-/private/tmp/claude-501/-Users-cicca-Documents-personal/22463735-b558-4f26-ba35-5d5dd2fd572c/scratchpad/model/ggml-base-q5_1.bin}"
ADB=(adb ${SERIAL:+-s "$SERIAL"})
PKG=vn.cicca.livetranslator
FILES=/sdcard/Android/data/$PKG/files

# Gradle installs on every connected device; with several, pass SERIAL (ANDROID_SERIAL narrows Gradle too)
[[ -n "${SERIAL:-}" ]] && export ANDROID_SERIAL="$SERIAL"
./gradlew -q --console=plain :app:installDebug :app:installDebugAndroidTest

# Test fixtures live in the app's external files dir (the phone may have no network)
"${ADB[@]}" shell mkdir -p "$FILES"
have() { "${ADB[@]}" shell "[ -f $FILES/$1 ]" 2>/dev/null; }
if ! have ggml-base-q5_1.bin; then
  if [[ -f "$WHISPER_MODEL" ]]; then
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
