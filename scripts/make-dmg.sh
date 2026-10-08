#!/bin/bash
# Builds a signed AppVolume DMG into ./build.
#   SIGN_IDENTITY  "Developer ID Application: ..." (default "-" = ad-hoc, runs only where Gatekeeper is bypassed)
#   NOTARY_PROFILE notarytool keychain profile; when set (with a Developer ID), notarizes and staples the DMG
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
APP=build/AppVolume.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/AppVolume-$VERSION.dmg"

scripts/build-app.sh

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements Resources/AppVolume.entitlements --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname AppVolume -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$DMG"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
codesign --verify --verbose=2 "$DMG"
echo "Built $DMG (signed with: $IDENTITY)"
