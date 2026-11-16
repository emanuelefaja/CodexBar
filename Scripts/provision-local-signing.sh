#!/usr/bin/env bash
# Provision a stable self-signed code-signing identity for local fork installs.
#
# Ad-hoc signatures change on every rebuild, which resets macOS TCC (Full Disk Access)
# and Keychain grants. A self-signed certificate keeps the same designated requirement,
# so permissions survive updates. The identity and its keychain are private to this Mac.
set -euo pipefail

DIR="$HOME/Library/Application Support/CodexBar/ForkSigning"
KC="$DIR/signing.keychain-db"
PW_FILE="$DIR/signing-keychain-password"
IDENTITY_NAME="CodexBar Local Signing"
umask 077

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$DIR/cert.pem" || ! -f "$DIR/key.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -subj "/CN=${IDENTITY_NAME}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  chmod 600 "$DIR/key.pem"
fi

if [[ ! -f "$PW_FILE" ]]; then
  openssl rand -base64 24 > "$PW_FILE"
  chmod 600 "$PW_FILE"
fi
PW="$(cat "$PW_FILE")"

if [[ ! -f "$KC" ]]; then
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
fi
security unlock-keychain -p "$PW" "$KC"

if ! security find-identity -v -p codesigning "$KC" | grep -q "$IDENTITY_NAME"; then
  if [[ ! -f "$DIR/identity.p12" ]]; then
    # OpenSSL 3 emits a PKCS#12 form that Security.framework cannot verify; use legacy algorithms.
    openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/identity.p12" \
      -name "$IDENTITY_NAME" -passout pass:localfork -legacy >/dev/null 2>&1
    chmod 600 "$DIR/identity.p12"
  fi
  security import "$DIR/identity.p12" -k "$KC" -P localfork \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1 || true
  # Trust the leaf for code signing in the user domain so codesign verification accepts it.
  security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" \
    "$DIR/cert.pem" >/dev/null 2>&1 || true
fi

# Keep the private keychain on the user search list so codesign can find the identity.
EXISTING="$(security list-keychains -d user | tr -d ' "')"
case "$EXISTING" in
  *"$KC"*) ;;
  *) security list-keychains -d user -s "$KC" $EXISTING ;;
esac

security find-identity -v -p codesigning "$KC" | grep -q "$IDENTITY_NAME" || {
  echo "ERROR: ${IDENTITY_NAME} is not a valid code-signing identity." >&2
  exit 1
}
