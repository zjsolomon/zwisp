#!/bin/bash
# Builds zwisp and installs it into /Applications.
# After this, open it once and use the menu-bar icon → "Launch at Login".
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh release

DEST="/Applications/zwisp.app"
echo "==> Installing to ${DEST}…"
# Quit any running copy so we can replace it.
osascript -e 'tell application "zwisp" to quit' 2>/dev/null || true
pkill -x zwisp 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R zwisp.app "$DEST"

echo "==> Launching…"
open "$DEST"

echo ""
echo "Installed. Next:"
echo "  1. Allow Microphone when prompted."
echo "  2. System Settings → Privacy & Security → Accessibility → enable zwisp."
echo "  3. Click the 🎙️ menu-bar icon → 'Launch at Login' to start on every boot."
echo "  4. Teach it names it mishears: menu-bar icon → Dictionary → Add Word…"
