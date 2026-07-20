#!/bin/bash
# Installs and launches the VisionDrop receiver on a Vision Pro.
# The headset must be awake and connected via the Developer Strap.
# Usage: scripts/install-receiver.sh [device-udid]   (auto-detects if omitted)
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p | sed 's|/Contents/Developer||')/Contents/Developer}"
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | grep -i 'vision pro' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}"
if [ -z "$DEVICE" ]; then
  echo "No paired Vision Pro found (xcrun devicectl list devices)"; exit 1
fi
APP=build-vision/Build/Products/Release-xros/VisionDropReceiver.app

if [ ! -d "$APP" ]; then
  xcodebuild -project VisionDrop.xcodeproj -scheme VisionDropReceiver -configuration Release \
    -destination 'generic/platform=visionOS' -derivedDataPath build-vision \
    -allowProvisioningUpdates build
fi

xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.rebelancap.visiondrop.receiver
echo "✅ VisionDrop receiver installed and launched on the Vision Pro"
