#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
identity='poteto Local Code Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
[ -f "$keychain" ] && [ ! -L "$keychain" ] || { echo 'A local login Keychain is required.' >&2; exit 1; }
count=$(/usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/grep -Fc "\"$identity\"" || true)
if [ "$count" = 1 ]; then
  echo "reusing $identity in login Keychain"
  exit 0
fi
[ "$count" = 0 ] || { echo 'Ambiguous poteto signing identities; nothing changed.' >&2; exit 1; }
if /usr/bin/security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo 'A poteto certificate exists without its signing key; refusing to replace it.' >&2
  exit 1
fi
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}poteto-signing-setup.XXXXXX")
trap '/bin/rm -rf "$temporary"' EXIT
cat > "$temporary/certificate.conf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = poteto Local Code Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$temporary/certificate.conf" -keyout "$temporary/key.pem" -out "$temporary/certificate.pem" >/dev/null 2>&1
/usr/bin/openssl rand -base64 36 > "$temporary/password"
/usr/bin/openssl pkcs12 -export -inkey "$temporary/key.pem" -in "$temporary/certificate.pem" -name "$identity" -out "$temporary/identity.p12" -passout "file:$temporary/password" >/dev/null 2>&1
# Only Apple's codesign may use this non-exportable key without a prompt.
/usr/bin/swiftc -suppress-warnings Tools/ImportSigningIdentity.swift -framework Security -o "$temporary/import-identity"
"$temporary/import-identity" "$temporary/identity.p12" "$keychain" < "$temporary/password"
count=$(/usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/grep -Fc "\"$identity\"" || true)
[ "$count" = 1 ] || { echo 'Signing identity import did not complete.' >&2; exit 1; }
echo "created $identity in login Keychain; no system trust settings changed"
