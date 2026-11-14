#!/bin/sh
# Snapshots of the redesigned screens from the iOS Simulator (demo mode, no board needed).
#
#   ios/Tools/snap.sh                    all 12 screens
#   ios/Tools/snap.sh welcome live       just these
#   ios/Tools/snap.sh lockactivity       the Live Activity in the Dynamic Island (over Settings), not in "all"
#   ios/Tools/snap.sh --delete-sim       delete the dedicated simulator and exit
#
# Generates the Xcode project, builds the app for the simulator, boots the snapshot simulator, installs, launches
# each screen with `-demo <screen>` (fakes + canvas sample data) and saves docs/ui-redesign/shots/<screen>.png.
#
# The simulator: SNAP_DEVICE names it (default "Snap iPhone 17 Pro"). If no simulator has that name it is created
# from SNAP_DEVICE_TYPE (default iPhone 17 Pro) on the newest iOS runtime, so your own simulators are never touched.
# Only that dedicated simulator is shut down at the end (if this script booted it) or deleted (--delete-sim).
# SNAP_WAIT sets the seconds to wait per screen (default 3), SNAP_WARMUP the first launch's (default 10).
#
# `simctl io screenshot` may not be allowed to write into the repository (sandboxed shells): every shot is taken
# into a temporary folder and moved into place. Errors are shown, never swallowed.
set -eu

ALL="welcome permissions pair language live lock phoneonly boardlost history glossary settings sharing"
EXTRA="lockactivity"
DEVICE="${SNAP_DEVICE:-Snap iPhone 17 Pro}"
DEVICE_TYPE="${SNAP_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
WAIT="${SNAP_WAIT:-3}"
BUNDLE_ID="dev.cicca.esptranslator"

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$IOS_DIR/.." && pwd)"
OUT="$REPO/docs/ui-redesign/shots"
DERIVED="$IOS_DIR/build/snap"

find_udid() {
    xcrun simctl list devices available | grep -F "    $DEVICE (" | head -n 1 \
        | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

if [ "${1:-}" = "--delete-sim" ]; then
    UDID="$(find_udid)"
    [ -n "$UDID" ] || { echo "no simulator named '$DEVICE'"; exit 0; }
    case "$DEVICE" in
        Snap*) ;;
        *) echo "refusing to delete '$DEVICE': only the dedicated 'Snap …' simulator is deleted" >&2; exit 2 ;;
    esac
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID"
    echo "deleted $DEVICE ($UDID)"
    exit 0
fi

SCREENS="${*:-$ALL}"
for s in $SCREENS; do
    case " $ALL $EXTRA " in *" $s "*) ;; *) echo "unknown screen: $s (known: $ALL $EXTRA)" >&2; exit 2 ;; esac
done
mkdir -p "$OUT"

UDID="$(find_udid)"
if [ -z "$UDID" ]; then
    RUNTIME="$(xcrun simctl list runtimes available | grep -E '^iOS ' | tail -n 1 \
        | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+).*/\1/')"
    [ -n "$RUNTIME" ] || { echo "no iOS simulator runtime installed (xcrun simctl list runtimes)" >&2; exit 1; }
    echo "==> create simulator '$DEVICE' ($DEVICE_TYPE, $RUNTIME)"
    UDID="$(xcrun simctl create "$DEVICE" "$DEVICE_TYPE" "$RUNTIME")"
fi

echo "==> xcodegen"
(cd "$IOS_DIR" && xcodegen generate --quiet)

echo "==> build for $DEVICE ($UDID)"
xcodebuild -project "$IOS_DIR/ESPTranslator.xcodeproj" -scheme ESPTranslator \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -quiet build
APP="$DERIVED/Build/Products/Debug-iphonesimulator/ESPTranslator.app"
[ -d "$APP" ] || { echo "build produced no app at $APP" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/snap.XXXXXX")"
WAS_BOOTED=0
xcrun simctl list devices | grep -F "($UDID) (Booted)" >/dev/null && WAS_BOOTED=1
cleanup() {
    rm -rf "$TMP"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
    [ "$WAS_BOOTED" = 1 ] || xcrun simctl shutdown "$UDID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> boot"
[ "$WAS_BOOTED" = 1 ] || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

echo "==> install"
xcrun simctl install "$UDID" "$APP"

# A fresh simulator shows system banners ("Ready for Apple Intelligence"…) for a few seconds after boot: let them
# pass on a throwaway launch so they never cover a shot. SNAP_WARMUP=0 skips it.
WARMUP="${SNAP_WARMUP:-10}"
if [ "$WARMUP" != 0 ]; then
    echo "==> warm-up (${WARMUP}s)"
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo welcome >/dev/null
    sleep "$WARMUP"
fi

for s in $SCREENS; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo "$s" >/dev/null
    sleep "$WAIT"
    if [ "$s" = "lockactivity" ]; then
        # The activity runs; another app in front shows it in the Dynamic Island
        xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
        sleep "$WAIT"
    fi
    xcrun simctl io "$UDID" screenshot --type=png "$TMP/$s.png" >/dev/null
    mv -f "$TMP/$s.png" "$OUT/$s.png"
    echo "    $s -> docs/ui-redesign/shots/$s.png"
done
echo "==> done"
