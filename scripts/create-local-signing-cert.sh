#!/bin/bash
# Creates a free, self-signed code-signing certificate named "Voicer Local Signing" in your login keychain.
# `make local` signs with it, so macOS sees the same app after every rebuild and keeps its permissions
# (Accessibility, Microphone, ...). Run it once. Safe to run again: it does nothing if the certificate exists.
set -euo pipefail

NAME="Voicer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
	echo "'$NAME' already exists in your login keychain."
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(uuidgen)

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-name "$NAME" -passout "pass:$PASS" -out "$WORK/cert.p12"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# macOS asks for your password here, so it trusts the certificate for code signing.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "Created '$NAME'. Run: make local"
echo "After the first build signed with it, macOS asks for permissions one last time."
