#!/bin/sh
# Snapshots of the redesigned screens from the iOS Simulator (demo mode, no board needed).
#
#   ios/Tools/snap.sh                 all 12 screens
#   ios/Tools/snap.sh welcome live    just these
#
# Generates the Xcode project, builds the app for the simulator, boots an iPhone 17 Pro, installs, launches each
# screen with `-demo <screen>` (fakes + canvas sample data), saves docs/ui-redesign/shots/<screen>.png and shuts
# the simulator down. SNAP_DEVICE overrides the device name, SNAP_WAIT the seconds to wait per screen.
set -eu

ALL="welcome permissions pair language live lock phoneonly boardlost history glossary settings sharing"
SCREENS="${*:-$ALL}"
DEVICE="${SNAP_DEVICE:-iPhone 17 Pro}"
WAIT="${SNAP_WAIT:-3}"
BUNDLE_ID="dev.cicca.esptranslator"

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$IOS_DIR/.." && pwd)"
OUT="$REPO/docs/ui-redesign/shots"
DERIVED="$IOS_DIR/build/snap"
mkdir -p "$OUT"

for s in $SCREENS; do
    case " $ALL " in *" $s "*) ;; *) echo "unknown screen: $s (known: $ALL)" >&2; exit 2 ;; esac
done

UDID="$(xcrun simctl list devices available | grep -m1 "    $DEVICE (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[ -n "$UDID" ] || { echo "no available simulator named '$DEVICE' (xcrun simctl list devices)" >&2; exit 1; }

echo "==> xcodegen"
(cd "$IOS_DIR" && xcodegen generate --quiet)

echo "==> build for $DEVICE ($UDID)"
xcodebuild -project "$IOS_DIR/ESPTranslator.xcodeproj" -scheme ESPTranslator \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -quiet build
APP="$DERIVED/Build/Products/Debug-iphonesimulator/ESPTranslator.app"
[ -d "$APP" ] || { echo "build produced no app at $APP" >&2; exit 1; }

echo "==> boot"
WAS_BOOTED=0
xcrun simctl list devices | grep -q "$UDID) (Booted)" && WAS_BOOTED=1
shutdown() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; }
trap shutdown EXIT
[ "$WAS_BOOTED" = 1 ] || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

echo "==> install"
xcrun simctl install "$UDID" "$APP"

for s in $SCREENS; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo "$s" >/dev/null
    sleep "$WAIT"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$s.png" >/dev/null 2>&1
    echo "    $s -> docs/ui-redesign/shots/$s.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" clear || true
echo "==> done (simulator shut down)"
