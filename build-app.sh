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
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer the stable self-signed identity (see setup-signing.sh) so the
# Accessibility/Microphone grants persist across rebuilds; fall back to ad-hoc.
IDENTITY="Zwhisper Self-Signed"
SIGN_KC="$HOME/Library/Keychains/zwhisper-codesign.keychain-db"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    [ -f "$SIGN_KC" ] && security unlock-keychain -p zwhisper "$SIGN_KC" 2>/dev/null || true
    echo "==> Code signing with \"$IDENTITY\" (stable identity)…"
    codesign --force --deep --keychain "$SIGN_KC" --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc code signing (run ./setup-signing.sh once to make grants persistent)…"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    First launch will prompt for Microphone; you must also grant"
echo "    Accessibility in System Settings → Privacy & Security → Accessibility."
