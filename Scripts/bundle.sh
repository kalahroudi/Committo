#!/usr/bin/env bash
# Builds Committo.app (+ bundled `committo` CLI) into ./dist. Requires macOS 14+ and Xcode 15+ / Swift 5.9+.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=dist/Committo.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CommittoApp" "$APP/Contents/MacOS/Committo"
mkdir -p "$APP/Contents/Resources/bin"; cp "$BIN/committo" "$APP/Contents/Resources/bin/committo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
