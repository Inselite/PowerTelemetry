#!/bin/bash
# Builds PowerTelemetry and assembles a redistributable .app bundle.
set -e
cd "$(dirname "$0")/.."

APP=PowerTelemetry.app

echo "Building release binary…"
swift build -c release

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PowerTelemetry "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# App icon (regenerate with: swift scripts/make_icon.swift . && iconutil -c icns AppIcon.iconset)
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/"
fi

# Ad-hoc signature: makes it a proper bundle for local use.
# Friends will need to right-click → Open once (Gatekeeper).
# With a paid Apple Developer account, replace this with:
#   codesign --sign "Developer ID Application: Your Name" ...
#   xcrun notarytool submit ... && xcrun stapler staple "$APP"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Done → $(pwd)/$APP"
