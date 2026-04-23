#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity for HandsFree.
# Run once. All subsequent xcodebuild runs will sign with this identity
# so macOS TCC (Accessibility, Input Monitoring, Mic) grants survive rebuilds.

set -euo pipefail

CERT_NAME="HandsFree Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SSL=/usr/bin/openssl

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "✓ Code-signing identity \"$CERT_NAME\" already exists."
  security find-identity -p codesigning | grep "$CERT_NAME"
  exit 0
fi

echo "Creating self-signed code-signing identity: $CERT_NAME"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions     = v3
prompt              = no

[dn]
CN = HandsFree Dev

[v3]
basicConstraints      = critical,CA:FALSE
keyUsage              = critical,digitalSignature
extendedKeyUsage      = critical,codeSigning
subjectKeyIdentifier  = hash
EOF

$SSL req -new -x509 -days 3650 -nodes \
  -keyout "$TMPDIR/key.pem" \
  -out    "$TMPDIR/cert.pem" \
  -config "$TMPDIR/openssl.cnf" >/dev/null 2>&1

# Try without -legacy (LibreSSL), fall back to -legacy (OpenSSL 3.x).
if ! $SSL pkcs12 -export \
  -inkey "$TMPDIR/key.pem" \
  -in    "$TMPDIR/cert.pem" \
  -out   "$TMPDIR/bundle.p12" \
  -passout pass:handsfree >/dev/null 2>&1; then
  $SSL pkcs12 -export -legacy \
    -inkey "$TMPDIR/key.pem" \
    -in    "$TMPDIR/cert.pem" \
    -out   "$TMPDIR/bundle.p12" \
    -passout pass:handsfree >/dev/null 2>&1
fi

security import "$TMPDIR/bundle.p12" \
  -P handsfree \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  >/dev/null

echo
echo "✓ Done."
echo
echo "  First xcodebuild after this will pop a keychain prompt asking if"
echo "  codesign can use the '$CERT_NAME' private key. Click \"Always Allow\"."
echo
security find-identity -p codesigning | grep "$CERT_NAME" || true
