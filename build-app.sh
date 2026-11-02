#!/bin/bash
# Build AISwitcher and package it into a proper macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="AI Switcher"
BUNDLE_ID="com.aiswitcher.app"
BUILD_DIR=".build/$CONFIG"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/AISwitcher" "$APP/Contents/MacOS/AISwitcher"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (Dock / Finder / About window).
if [ -f Sources/AISwitcher/Resources/Assets/AppIcon.icns ]; then
    cp Sources/AISwitcher/Resources/Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Menu-bar and provider artwork load from the standard app resource directory first.
for asset in Sources/AISwitcher/Resources/Assets/MenuBarTemplate.* Sources/AISwitcher/Resources/Assets/MenuBarTemplate@2x.png Sources/AISwitcher/Resources/Assets/MenuBarTemplate@3x.png Sources/AISwitcher/Resources/Assets/Provider*.svg; do
    if [ -f "$asset" ]; then
        cp "$asset" "$APP/Contents/Resources/"
    fi
done

# Localized resources (.lproj) + any bundled resource bundle from SwiftPM.
for lproj in Sources/AISwitcher/Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done
# `Bundle.module` looks for the SwiftPM resource bundle next to the app's
# resources; newer toolchains no longer fall back to the absolute build path.
if [ -d "$BUILD_DIR/AISwitcher_AISwitcher.bundle" ]; then
    cp -R "$BUILD_DIR/AISwitcher_AISwitcher.bundle" "$APP/Contents/Resources/"
fi
echo "==> ad-hoc code sign"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "==> built: $APP"
