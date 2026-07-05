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

# Enable the "Add to zwisp Dictionary" Service (right-click on selected text)
# and give it its default shortcut, ⌃⌥⇧⌘Z — macOS is lazy about surfacing newly
# installed services, and a service without a shortcut is a service nobody
# uses. All four modifiers ("hyper") deliberately: macOS Sequoia's window
# tiling took over many ⌃⌥⌘ combos (⌃⌥⌘Z zooms the window), and no system or
# mainstream app binds 4-modifier chords. Skipped when an entry already
# exists, so a shortcut the user customised in System Settings survives
# reinstalls. "^~$@z" = Control Option Shift Command Z.
echo "==> Registering the dictionary Service (⌃⌥⇧⌘Z)…"
if ! defaults read pbs NSServicesStatus 2>/dev/null | grep -q "com.local.zwisp"; then
    defaults write pbs NSServicesStatus -dict-add \
        "com.local.zwisp - Add to zwisp Dictionary - addToDictionary" \
        '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "key_equivalent" = "^~$@z"; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
fi
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall pbs 2>/dev/null || true

echo "==> Launching…"
open "$DEST"

echo ""
echo "Installed. Next:"
echo "  1. Allow Microphone when prompted."
echo "  2. System Settings → Privacy & Security → Accessibility → enable zwisp."
echo "  3. Click the 🎙️ menu-bar icon → 'Launch at Login' to start on every boot."
echo "  4. Teach it names it mishears: select the correct spelling anywhere and"
echo "     press ⌃⌥⇧⌘Z (or right-click → Services → Add to zwisp Dictionary)."
