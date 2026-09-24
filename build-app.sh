#!/bin/bash
# Builds zwisp and wraps the binary in a proper .app bundle so macOS can grant
# Microphone + Accessibility permissions (these are tied to a signed app bundle).
# Also bundles the pinned llama-server (the AI-cleanup engine) into Resources.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="zwisp.app"

# Pinned llama.cpp release serving the cleanup model. The ngram-speculation
# flags in Configuration.swift were tuned against exactly this build — bump the
# two together, re-verifying the SHA256 from the GitHub release page.
LLAMA_BUILD="b9964"
LLAMA_TARBALL="llama-${LLAMA_BUILD}-bin-macos-arm64.tar.gz"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/${LLAMA_TARBALL}"
LLAMA_SHA256="ef6ddf8b990b5965c96d3b794267f7571a1784d5774baf0835b52c0c3b005e24"
LLAMA_CACHE=".build/llama-cache/${LLAMA_BUILD}"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/zwisp"

fetch_llama() {
    [ -x "$LLAMA_CACHE/llama-server" ] && return
    echo "==> Fetching llama.cpp ${LLAMA_BUILD}…"
    mkdir -p "$LLAMA_CACHE"
    local tarball="$LLAMA_CACHE/$LLAMA_TARBALL"
    curl -fsSL -o "$tarball" "$LLAMA_URL"
    echo "$LLAMA_SHA256  $tarball" | shasum -a 256 -c - >/dev/null
    tar -xzf "$tarball" -C "$LLAMA_CACHE" --strip-components=1
    rm "$tarball"
}
fetch_llama

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/llama"
cp "$BIN" "$APP/Contents/MacOS/zwisp"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The server + every dylib, flat, exactly as the release ships them so the
# binary's @rpath/@loader_path references resolve in place. -a preserves the
# version symlinks (libllama.dylib → libllama.0.…) instead of tripling the
# payload with dereferenced copies. LICENSE rides along (llama.cpp is MIT).
cp -a "$LLAMA_CACHE/llama-server" "$LLAMA_CACHE"/*.dylib "$LLAMA_CACHE/LICENSE" \
   "$APP/Contents/Resources/llama/"

# Signing identity, in order of preference:
#   1. $ZWISP_SIGN_IDENTITY, if set (a name or SHA-1 from `security find-identity`);
#   2. the Developer ID Application certificate (see README → Releasing) — the shipping
#      identity, used for dev builds too so the app has ONE code identity and the
#      Accessibility/Input Monitoring grants persist across every rebuild;
#   3. the self-signed identity from setup-signing.sh (same persistence, but
#      Gatekeeper treats it as unsigned on any other Mac);
#   4. ad-hoc, which may require re-granting Accessibility after each rebuild.
# A Developer ID signature is made with the hardened runtime + a trusted
# timestamp, as notarization requires (release.sh); the self-signed and ad-hoc
# paths skip both — the timestamp needs the network, and the hardened runtime
# needs a real identity to mean anything.
SELF_SIGNED="zwisp Self-Signed"
SELF_KC="$HOME/Library/Keychains/zwisp-codesign.keychain-db"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
DEV_ID="$(echo "$IDENTITIES" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
ENTITLEMENTS="zwisp.entitlements"
if [ -n "${ZWISP_SIGN_IDENTITY:-}" ]; then
    echo "==> Code signing with \"$ZWISP_SIGN_IDENTITY\" (ZWISP_SIGN_IDENTITY)…"
    SIGN_ARGS=(--force --sign "$ZWISP_SIGN_IDENTITY" --options runtime --timestamp)
    HARDENED=1
elif [ -n "$DEV_ID" ]; then
    echo "==> Code signing with \"$DEV_ID\" (hardened runtime, timestamped)…"
    SIGN_ARGS=(--force --sign "$DEV_ID" --options runtime --timestamp)
    HARDENED=1
elif echo "$IDENTITIES" | grep -q "$SELF_SIGNED"; then
    [ -f "$SELF_KC" ] && security unlock-keychain -p zwisp "$SELF_KC" 2>/dev/null || true
    echo "==> Code signing with \"$SELF_SIGNED\" (stable identity, not notarizable)…"
    SIGN_ARGS=(--force --keychain "$SELF_KC" --sign "$SELF_SIGNED")
    HARDENED=0
else
    echo "==> Ad-hoc code signing (run ./setup-signing.sh once to make grants persistent)…"
    SIGN_ARGS=(--force --sign -)
    HARDENED=0
fi
# Nested Mach-Os first (codesign --deep doesn't re-sign executables that live
# under Resources), then the bundle itself. Real files only: the version
# symlinks resolve to the same dylibs, and each signature costs a timestamp
# round trip. The engine gets the hardened runtime with no entitlements — its
# dylibs carry the same Team ID, so library validation passes.
find "$APP/Contents/Resources/llama" -type f -name '*.dylib' -print0 \
    | xargs -0 codesign "${SIGN_ARGS[@]}"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/llama/llama-server"
if [ "$HARDENED" = 1 ]; then
    codesign --deep "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
else
    codesign --deep "${SIGN_ARGS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    First launch will prompt for Microphone; you must also grant"
echo "    Accessibility in System Settings → Privacy & Security → Accessibility."
