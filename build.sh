#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
identity='poteto Local Code Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
count=$(/usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/grep -Fc "\"$identity\"" || true)
[ "$count" = 1 ] || { echo 'Fixed poteto signing identity required. Run bash setup-signing.sh once; no ad-hoc fallback.' >&2; exit 1; }
if [ "${1:-}" = "--release" ]; then
  [ "$#" = 2 ] || { echo 'Usage: bash build.sh --release /absolute/path/poteto.app' >&2; exit 1; }
  app="$2"
  [[ "$app" = /*/poteto.app ]] || { echo 'Release app path must be absolute and end in poteto.app' >&2; exit 1; }
  [ ! -e "$app" ] && [ ! -L "$app" ] || { echo 'Release app already exists' >&2; exit 1; }
  parent="$(dirname "$app")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || { echo 'Release parent must be a directory, not a symlink' >&2; exit 1; }
  staging=$(/usr/bin/mktemp -d "$parent/.poteto-build.XXXXXXXX")
  release=1
else
  staging="$PWD/build/.poteto-staging.noindex"
  app="$staging/poteto-staging.app"
  release=0
fi
if [ "$release" = 0 ]; then
  [ ! -L "$PWD/build" ] || { echo "Refusing to build through a symlink: $PWD/build" >&2; exit 1; }
fi
for path in "$staging" "$app"; do
  [ ! -L "$path" ] || { echo "Refusing to build through a symlink: $path" >&2; exit 1; }
done
if [ -e "$app" ]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  [ "$bundle_id" = io.poteto.menubar ] || { echo 'Refusing to replace an unrelated staging app' >&2; exit 1; }
fi
/bin/rm -rf "$app"
if [ "$release" = 1 ]; then
  trap '/bin/rm -rf "$app" "$staging"' EXIT
else
  trap '/bin/rm -rf "$app"' EXIT
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.poteto.menubar</string>
<key>CFBundleName</key><string>poteto</string>
<key>CFBundleDisplayName</key><string>poteto</string>
<key>CFBundleExecutable</key><string>poteto</string>
<key>CFBundleIconFile</key><string>poteto.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "$release" = 1 ]; then
  for arch in arm64 x86_64; do
    /usr/bin/swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macosx14.0" \
      -file-prefix-map "$HOME=/private-home" -debug-prefix-map "$HOME=/private-home" \
      -file-prefix-map "$PWD=/poteto" -debug-prefix-map "$PWD=/poteto" \
      Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift \
      -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o "$staging/poteto-$arch"
  done
  /usr/bin/lipo -create "$staging/poteto-arm64" "$staging/poteto-x86_64" -output "$app/Contents/MacOS/poteto"
  /bin/rm -f "$staging/poteto-arm64" "$staging/poteto-x86_64"
else
  /usr/bin/swiftc -swift-version 5 -O -parse-as-library Sources/Core.swift Sources/Activation.swift Sources/Panel.swift Sources/PotetoApp.swift -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -o "$app/Contents/MacOS/poteto"
fi
/usr/bin/swift Tools/Icon.swift "$staging/poteto.iconset"
/usr/bin/iconutil --convert icns "$staging/poteto.iconset" --output "$app/Contents/Resources/poteto.icns"
/bin/rm -rf "$staging/poteto.iconset"
if [ "$release" = 1 ]; then /usr/bin/xattr -cr "$app"; fi
/usr/bin/codesign --force --sign "$identity" --keychain "$keychain" --identifier io.poteto.menubar "$app"
/usr/bin/codesign --verify --strict "$app"
if [ "$release" = 1 ]; then
  /bin/rm -rf "$staging"
fi
trap - EXIT
if [ "$release" = 1 ]; then
  echo "built $app"
else
  echo "built $app (temporary; use bash install.sh to install)"
fi
