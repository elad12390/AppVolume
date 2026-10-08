#!/bin/bash
# Builds AppVolume.app into ./build (ad-hoc signed). Usage: scripts/build-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AppVolume"
APP=build/AppVolume.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppVolume"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x AppVolume 2>/dev/null || true
  open "$APP"
fi
