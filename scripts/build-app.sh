#!/bin/bash
# Builds AppVolume.app into ./build (ad-hoc signed). Usage: scripts/build-app.sh [--open]
#   UNIVERSAL=1  build for Apple Silicon and Intel (needs Xcode, not just the Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/AppVolume"
APP=build/AppVolume.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppVolume"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/AppVolume"))"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x AppVolume 2>/dev/null || true
  open "$APP"
fi
