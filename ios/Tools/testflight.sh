#!/bin/zsh
# ios/Tools/testflight.sh: archive the app and upload it to TestFlight with an App Store Connect API key.
#
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-... ios/Tools/testflight.sh
#
# The key file is ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (Admin role: it also creates the
# signing certificate and profiles). The build number is bumped to the current time so every upload is unique;
# MARKETING_VERSION stays as set in project.yml. The team is DEVELOPMENT_TEAM in project.yml.
set -euo pipefail

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$KEY" ]] || { echo "missing $KEY" >&2; exit 1; }

cd "${0:A:h}/.."
TEAM=$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)
BUILD=$(date +%Y%m%d%H%M)
OUT=$(mktemp -d)
AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
# Xcode's IPA step calls /usr/bin/rsync, which breaks when Homebrew's rsync 3.x is first in PATH
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

xcodegen generate >/dev/null
xcodebuild -project ESPTranslator.xcodeproj -scheme ESPTranslator -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/app.xcarchive" -allowProvisioningUpdates "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/app.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error|Upload succeeded|EXPORT (SUCCEEDED|FAILED)"
echo "uploaded build $BUILD"
