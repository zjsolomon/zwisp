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

# Prefer the stable self-signed identity (see setup-signing.sh) so the
# Accessibility/Microphone grants persist across rebuilds; fall back to ad-hoc.
IDENTITY="zwisp Self-Signed"
SIGN_KC="$HOME/Library/Keychains/zwisp-codesign.keychain-db"
SIGN_ARGS=(--force --sign -)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    [ -f "$SIGN_KC" ] && security unlock-keychain -p zwisp "$SIGN_KC" 2>/dev/null || true
    echo "==> Code signing with \"$IDENTITY\" (stable identity)…"
    SIGN_ARGS=(--force --keychain "$SIGN_KC" --sign "$IDENTITY")
else
    echo "==> Ad-hoc code signing (run ./setup-signing.sh once to make grants persistent)…"
fi
# Nested Mach-Os first (codesign --deep doesn't re-sign executables that live
# under Resources), then the bundle itself.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/llama/"*.dylib \
                           "$APP/Contents/Resources/llama/llama-server"
codesign --deep "${SIGN_ARGS[@]}" "$APP"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    First launch will prompt for Microphone; you must also grant"
echo "    Accessibility in System Settings → Privacy & Security → Accessibility."
