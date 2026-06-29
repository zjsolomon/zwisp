#!/bin/bash
# Builds Zwhisper and wraps the binary in a proper .app bundle so macOS can grant
# Microphone + Accessibility permissions (these are tied to a signed app bundle).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Zwhisper.app"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Zwhisper"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Zwhisper"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    First launch will prompt for Microphone; you must also grant"
echo "    Accessibility in System Settings → Privacy & Security → Accessibility."
