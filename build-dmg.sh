#!/bin/bash
# Packages the already-built zwisp.app into a branded, notarized disk image:
# dist/zwisp.dmg. release.sh runs it after notarizing and stapling the app;
# it can also be run on its own, on an app that's already stapled.
#
# The Finder window shows zwisp.app on the left, an Applications shortcut on
# the right, and the backdrop from Assets/dmg-background.png between them.
# The DMG is signed with the same Developer ID, notarized and stapled, so it
# opens without any Gatekeeper prompt.
#
#   ./build-dmg.sh                 # needs the "homebird-notary" notarytool profile
#   ./build-dmg.sh --no-notarize   # local test build only
set -euo pipefail
cd "$(dirname "$0")"

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0
NOTARY_PROFILE="${NOTARY_PROFILE:-homebird-notary}"

APP="zwisp.app"
VOLNAME="zwisp"
DIST="dist"
STAGE="$DIST/stage"
OUT_DMG="$DIST/zwisp.dmg"
RW_DMG="$DIST/zwisp-rw.dmg"
BACKGROUND="Assets/dmg-background.png"
# Finder window geometry in points. It must match the DMG_* constants in
# Assets/generate-logo.py, which draws the backdrop. Finder's window bounds
# include the title bar, so that's added on top of the backdrop's height.
WIN_W=660; WIN_H=380; TITLEBAR=28
ICON_Y=225; APP_X=165; APPS_X=495
ICON_SIZE=128

[ -d "$APP" ] || { echo "==> No $APP. Run ./build-app.sh release (or ./release.sh) first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
SIGNATURE=$(codesign -dv --verbose=2 "$APP" 2>&1)
DEV_ID=$(echo "$SIGNATURE" | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
if [ "$NOTARIZE" = 1 ]; then
    [ -n "$DEV_ID" ] || { echo "==> $APP isn't signed with a Developer ID; can't notarize." >&2; exit 1; }
    xcrun stapler validate -q "$APP" || { echo "==> $APP isn't notarized and stapled yet (run ./release.sh)." >&2; exit 1; }
fi

echo "==> Packaging $APP $VERSION into ${OUT_DMG}…"
hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true   # leftovers from an interrupted run
rm -rf "$STAGE" "$RW_DMG" "$OUT_DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.png"
chflags hidden "$STAGE/.background"

# A read-write image first, so Finder can save the window layout into it.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov -quiet "$RW_DMG"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
        | grep -E '^/dev/' | sed -E 's|.*(/Volumes/.*)$|\1|' | tail -1)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

echo "==> Laying out the Finder window…"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set win to container window
        set current view of win to icon view
        set toolbar visible of win to false
        set statusbar visible of win to false
        set pathbar visible of win to false
        set bounds of win to {200, 120, $((200 + WIN_W)), $((120 + TITLEBAR + WIN_H))}
        set opts to icon view options of win
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "$APP" of win to {$APP_X, $ICON_Y}
        set position of item "Applications" of win to {$APPS_X, $ICON_Y}
        -- Park the dot-folders off-window for Finders that show hidden files.
        set position of item ".background" of win to {$((WIN_W + 200)), $ICON_Y}
        try
            set position of item ".fseventsd" of win to {$((WIN_W + 400)), $ICON_Y}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
trap - EXIT

echo "==> Compressing…"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$OUT_DMG"
rm -rf "$RW_DMG" "$STAGE"

if [ "$NOTARIZE" = 0 ]; then
    [ -n "$DEV_ID" ] && codesign --sign "$DEV_ID" --timestamp "$OUT_DMG"
    echo "==> Built (NOT notarized, local testing only): $OUT_DMG"
    exit 0
fi

codesign --sign "$DEV_ID" --timestamp "$OUT_DMG"
echo "==> Notarizing $OUT_DMG (usually a few minutes)…"
OUT=$(xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$OUT" | grep -E "^  (id|status):" | sed 's/^/  /' | sort -u
if [[ "$OUT" != *"status: Accepted"* ]]; then
    ID=$(echo "$OUT" | awk '/^  id:/ {print $2; exit}')
    echo "==> Apple didn't accept the DMG. Its log:" >&2
    if [ -n "$ID" ]; then xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2; else echo "$OUT" >&2; fi
    exit 1
fi
xcrun stapler staple -q "$OUT_DMG"
xcrun stapler validate -q "$OUT_DMG"
spctl --assess --type open --context context:primary-signature "$OUT_DMG"
echo "==> Notarized and stapled: $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1), version $VERSION)"
