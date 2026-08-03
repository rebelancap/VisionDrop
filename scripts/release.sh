#!/bin/bash
# Builds, signs (Developer ID via archive/export — supports cloud-managed
# certificates), notarizes, and staples the Mac app, producing a
# distributable zip.
#
# One-time setup on a new Mac:
#   1. xcrun notarytool store-credentials <profile> \
#        --key ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 \
#        --key-id <ID> --issuer <ISSUER-UUID>
#   2. scripts/release.env (gitignored) with:
#        ASC_KEY_ID=<ID>
#        ASC_ISSUER_ID=<ISSUER-UUID>
#      (key file expected at ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
#   3. A Developer ID Application certificate on the account — the Account
#      Holder creates a cloud-managed one once via Xcode → Settings →
#      Accounts → Manage Certificates → "+".
# Usage: scripts/release.sh <notarytool-profile> [version]
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${1:?usage: release.sh <notarytool-keychain-profile> [version]}"
VERSION="${2:-1.0.1}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -f scripts/release.env ] && source scripts/release.env
: "${ASC_KEY_ID:?set ASC_KEY_ID in scripts/release.env}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in scripts/release.env}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

xcodegen generate
xcodebuild archive -project VisionDrop.xcodeproj -scheme VisionDrop -configuration Release \
  -archivePath build-release/VisionDrop.xcarchive -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  ENABLE_HARDENED_RUNTIME=YES \
  | grep -E ' error|warning: Code|ARCHIVE ' || true

EXPORT_PLIST=$(mktemp -t vd-export).plist
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>57G8J46Z2T</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

rm -rf build-release/export
xcodebuild -exportArchive \
  -archivePath build-release/VisionDrop.xcarchive \
  -exportPath build-release/export \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
rm -f "$EXPORT_PLIST"

APP=build-release/export/VisionDrop.app
codesign --verify --strict --deep "$APP"
ZIP="VisionDrop-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP" 2>&1 | tail -2
echo "✅ Notarized, stapled, packaged: $ZIP"
