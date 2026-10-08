#!/bin/bash
# Renders Resources/AppIcon.icns (and docs/icon.png for the README) from scripts/icon/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/AppIcon.iconset"

swiftc -O scripts/icon/main.swift -o "$WORK/render"
"$WORK/render" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$WORK/AppIcon.iconset/icon_128x128@2x.png" docs/icon.png
echo "Wrote Resources/AppIcon.icns and docs/icon.png"
