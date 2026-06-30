#!/bin/bash
# OPTIONAL, run once. Creates a stable self-signed code-signing identity and
# trusts it for code signing. After this, build-app.sh signs with it instead of
# ad-hoc, so macOS keeps the SAME code identity across rebuilds — meaning you
# only grant Accessibility/Microphone ONCE, not after every rebuild.
#
# This will prompt (GUI or sudo) to add a trust setting for the certificate.
set -euo pipefail

KC="$HOME/Library/Keychains/zwhisper-codesign.keychain-db"
KCPASS="zwhisper"
CN="Zwhisper Self-Signed"

# Consider it done only if the identity is present AND valid (no trust error
# annotation like CSSMERR_TP_NOT_TRUSTED on its line).
if security find-identity -v -p codesigning 2>/dev/null | grep "$CN" | grep -qv "("; then
  echo "Signing identity \"$CN\" already set up and trusted. Nothing to do."
  exit 0
fi

echo "==> Creating keychain + certificate…"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"               # disable auto-lock
security unlock-keychain -p "$KCPASS" "$KC"
EXISTING=$(security list-keychains -d user | sed 's/"//g' | xargs)
security list-keychains -d user -s "$KC" $EXISTING

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
  -days 3650 -nodes -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# -legacy so the macOS Security framework can import the PKCS12.
openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
  -out "$TMP/c.p12" -passout pass:"$KCPASS" -name "$CN"
security import "$TMP/c.p12" -k "$KC" -P "$KCPASS" -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

echo "==> Trusting the certificate for code signing (enter your password when sudo asks)…"
# Admin-domain trust (System keychain) is reliably honored by codesign;
# user-domain trust is not. This is why we use sudo here.
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain "$TMP/c.pem"

echo "==> Verifying trust…"
if security find-identity -v -p codesigning | grep "$CN" | grep -qv "("; then
  security find-identity -v -p codesigning | grep "$CN"
  echo "Success: \"$CN\" is now trusted for code signing."
else
  echo "WARNING: identity still NOT trusted (was the password prompt cancelled?)."
  exit 1
fi

echo ""
echo "Now run ./install.sh again, then grant Accessibility once more — it will"
echo "stick across all future rebuilds."
