#!/bin/bash
# Compiles the production sender + receiver engines into a CLI harness and runs
# a real 4-stream transfer over 127.0.0.1, verifying bytes and cleanup.
set -e
cd "$(dirname "$0")/.."
if pgrep -xq VisionDrop; then
  echo "⚠️  Quit the VisionDrop app first — it owns port 17777 and would receive the test transfers."
  exit 1
fi
OUT=$(mktemp -d)
xcrun swiftc -O \
  Shared/WireProtocol.swift Shared/TransferItem.swift Shared/NetUtils.swift \
  Shared/BSDSocket.swift Shared/SenderModel.swift Shared/ReceiverModel.swift \
  Tests/Loopback/main.swift -o "$OUT/loopback-test"
"$OUT/loopback-test" "$OUT/vd-loopback"
