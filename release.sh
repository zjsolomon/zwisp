#!/bin/bash
# Builds a release zwisp.app, notarizes it, and zips it for Homebird to install.
#
#   ./release.sh            # version from Info.plist → dist/zwisp-<v>.zip + catalog entry
#   ./release.sh --publish  # …and uploads it as GitHub release v<v> on zjsolomon/zwisp
#
# Notarization needs the Developer ID Application certificate in the keychain
# and the notarytool credentials saved once as the "homebird-notary" profile:
#   xcrun notarytool store-credentials homebird-notary --apple-id <email> --team-id <team>
# Without them the zip is still built (for local testing) but --publish refuses.
#
# The printed fields are the `version`/`downloadURL`/`sha256`/`byteSize` part of
# zwisp's entry in Homebird's catalog.json. Paste them there after publishing.
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1
NOTARY_PROFILE="${NOTARY_PROFILE:-homebird-notary}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="dist/zwisp-${VERSION}.zip"
URL="https://github.com/zjsolomon/zwisp/releases/download/v${VERSION}/zwisp-${VERSION}.zip"

./build-app.sh release
mkdir -p dist

# ditto keeps the bundle's symlinks, extended attributes and code signature intact.
zip_app() { rm -f "$ZIP"; ditto -c -k --keepParent zwisp.app "$ZIP"; }

NOTARIZED=0
# Captured first: `codesign | grep -q` under pipefail fails when grep exits early.
SIGNATURE=$(codesign -dv zwisp.app 2>&1)
if [[ "$SIGNATURE" == *"TeamIdentifier="* && "$SIGNATURE" != *"TeamIdentifier=not set"* ]] \
   && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing (this usually takes a few minutes)…"
    zip_app
    OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$OUT" | grep -E "id:|status:" | tail -2
    if [[ "$OUT" != *"status: Accepted"* ]]; then
        ID=$(echo "$OUT" | awk '/^  id:/ {print $2; exit}')
        echo "==> Apple rejected the app. Its log:" >&2
        [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    # Staple the ticket to the app so Gatekeeper can check it offline.
    xcrun stapler staple zwisp.app
    NOTARIZED=1
else
    echo "==> Not notarizing: needs the Developer ID certificate and the \"$NOTARY_PROFILE\" notarytool profile."
fi

echo "==> Zipping ${ZIP}…"
zip_app
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f %z "$ZIP")

if [ "$PUBLISH" = 1 ]; then
    if [ "$NOTARIZED" != 1 ]; then
        echo "==> Refusing to publish an app that isn't notarized." >&2
        exit 1
    fi
    echo "==> Publishing GitHub release v${VERSION}…"
    gh release create "v${VERSION}" "$ZIP" --repo zjsolomon/zwisp \
        --title "zwisp ${VERSION}" --notes "zwisp ${VERSION}. Install it with Homebird."
fi

cat <<EOF

==> Catalog entry fields:
    "version": "${VERSION}",
    "downloadURL": "${URL}",
    "sha256": "${SHA}",
    "byteSize": ${SIZE}
EOF
