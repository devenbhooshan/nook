#!/bin/bash
# One-time setup: creates a local code-signing certificate so every build of Nook keeps the same identity.
#
# Why: builds are otherwise signed "ad hoc", and macOS treats each rebuild as a different app, so it asks
# you to approve Keychain access again after every build. With a stable certificate, it asks at most once.
#
# The certificate lives in its own small keychain under ~/Library/Application Support/Nook/Signing, not in
# your login keychain. macOS asks for your Mac password once, to trust it for code signing.
# For public releases, sign with an Apple Developer ID instead.
set -euo pipefail

name="Nook Local Signing"
dir="$HOME/Library/Application Support/Nook/Signing"
keychain="$dir/signing.keychain-db"
# This only protects the throwaway keychain that holds the signing key, nothing else.
password="nook-local-signing"

if [[ -f "$keychain" ]] && security find-identity -v -p codesigning "$keychain" | grep -q "$name"; then
    echo "Already set up: builds are signed with \"$name\"."
    exit 0
fi

mkdir -p "$dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
    -out "$tmp/identity.p12" -passout pass:"$password" 2>/dev/null \
    || openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
        -out "$tmp/identity.p12" -passout pass:"$password"

rm -f "$keychain"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"   # don't auto-lock
security unlock-keychain -p "$password" "$keychain"
security import "$tmp/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null

echo "macOS will now ask for your Mac password to trust \"$name\" for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

if security find-identity -v -p codesigning "$keychain" | grep -q "$name"; then
    echo "Done. Run ./scripts/build-app.sh and future builds keep the same identity."
else
    echo "The certificate was created but isn't trusted for code signing yet." >&2
    exit 1
fi
