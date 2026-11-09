#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}poteto-signing-smoke.XXXXXX")
keychain="$temporary/fixture.keychain"
cleanup() {
  if [ -f "$keychain" ] && [ -x "$temporary/original" ]; then
    "$temporary/original" cleanup "$keychain" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$temporary"
}
trap cleanup EXIT
for version in original updated; do
  flags=(-suppress-warnings)
  [ "$version" = original ] || flags+=(-D UPDATED_BINARY)
  /usr/bin/swiftc "${flags[@]}" Tests/SigningKeychainSmoke.swift -framework Security -o "$temporary/$version"
  /usr/bin/codesign --force --sign 'poteto Local Code Signing' --keychain "$HOME/Library/Keychains/login.keychain-db" --identifier io.poteto.signing-smoke "$temporary/$version"
  /usr/bin/codesign --verify --strict "$temporary/$version"
done
/bin/cp "$temporary/updated" "$temporary/untrusted"
/usr/bin/codesign --force --sign - --identifier io.poteto.signing-smoke "$temporary/untrusted"
"$temporary/original" create "$keychain"
"$temporary/original" read "$keychain"
"$temporary/updated" read "$keychain"
"$temporary/untrusted" deny "$keychain"
"$temporary/original" read "$keychain"
echo 'PASS: rebuilt binary retains Keychain access; a different signing identity is still denied'
if [ "${1:-}" = --native-vault ]; then
  /usr/bin/swiftc -swift-version 5 -parse-as-library Sources/Core.swift Tests/SigningVaultSmoke.swift -framework Security -framework LocalAuthentication -o "$temporary/vault-reader"
  /usr/bin/codesign --force --sign 'poteto Local Code Signing' --keychain "$HOME/Library/Keychains/login.keychain-db" --identifier io.poteto.menubar "$temporary/vault-reader"
  /usr/bin/codesign --verify --strict "$temporary/vault-reader"
  "$temporary/vault-reader" --read-poteto-vault
fi
