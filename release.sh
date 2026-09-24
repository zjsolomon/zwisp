#!/bin/bash
# Builds a release zwisp.app and zips it for Homebird to install.
#
#   ./release.sh            # version from Info.plist → dist/zwisp-<v>.zip + catalog entry
#   ./release.sh --publish  # …and uploads it as GitHub release v<v> on zjsolomon/zwisp
#
# The printed JSON is the `version`/`downloadURL`/`sha256`/`byteSize` part of
# zwisp's entry in Homebird's catalog.json — paste it there after publishing.
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="dist/zwisp-${VERSION}.zip"
URL="https://github.com/zjsolomon/zwisp/releases/download/v${VERSION}/zwisp-${VERSION}.zip"

./build-app.sh release

echo "==> Zipping ${ZIP}…"
mkdir -p dist
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, extended attributes and code signature intact.
ditto -c -k --keepParent zwisp.app "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f %z "$ZIP")

if [ "$PUBLISH" = 1 ]; then
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
