#!/bin/bash
# Renders docs/demo.gif and the README screenshots from the real SwiftUI views with sample apps.
# Needs ffmpeg (brew install ffmpeg). App icons come from /Applications when present.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/frames" docs

SOURCES=$(ls Sources/AppVolume/*.swift | grep -v AppVolumeApp.swift)
swiftc -swift-version 5 -O $SOURCES scripts/demo/main.swift -o "$WORK/render"
"$WORK/render" "$WORK/frames" docs

ffmpeg -loglevel error -y -framerate 20 -i "$WORK/frames/f%04d.png" \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 docs/demo.gif
echo "Wrote docs/demo.gif ($(du -h docs/demo.gif | cut -f1))"
