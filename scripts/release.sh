#!/bin/bash
# Builds, signs (Developer ID + hardened runtime), notarizes, and staples the
# Mac app, producing a distributable zip.
#
# One-time setup: xcrun notarytool store-credentials <profile> \
#                   --apple-id <you@example.com> --team-id <TEAMID>
# Usage:          scripts/release.sh <notarytool-profile> [version]
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${1:?usage: release.sh <notarytool-keychain-profile> [version]}"
VERSION="${2:-1.0.0}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodegen generate
xcodebuild -project VisionDrop.xcodeproj -scheme VisionDrop -configuration Release \
  -derivedDataPath build-release \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  clean build | grep -E ' error|warning: Code|BUILD ' || true

APP=build-release/Build/Products/Release/VisionDrop.app
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
