#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
staging="$PWD/build/.poteto-staging.noindex"
app="$staging/poteto-staging.app"
legacy="$PWD/build/poteto.app"
target="$HOME/Applications/poteto.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
requirement='=identifier "io.poteto.menubar" and certificate leaf[subject.CN] = "poteto Local Code Signing"'
for path in "$PWD/build" "$staging" "$HOME/Applications" "$app" "$legacy" "$target"; do
  [ ! -L "$path" ] || { echo "Refusing to install through a symlink: $path" >&2; exit 1; }
done
for bundle in "$app" "$legacy" "$target"; do
  if [ -e "$bundle" ]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
    [ "$bundle_id" = io.poteto.menubar ] || { echo "Refusing to overwrite or remove an unrelated app: $bundle" >&2; exit 1; }
  fi
done
[ -x "$app/Contents/MacOS/poteto" ] || bash build.sh
/usr/bin/codesign --verify --strict -R "$requirement" "$app"
if [ -e "$target" ]; then
  /bin/launchctl bootout "gui/$(id -u)/io.poteto.menubar" 2>/dev/null || true
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$app" "$target"
/usr/bin/codesign --verify --strict -R "$requirement" "$target"
for temporary_app in "$legacy" "$app"; do
  # Unregister only these project paths, including a stale entry whose file is gone.
  "$lsregister" -u "$temporary_app" >/dev/null 2>&1 || true
  /bin/rm -rf "$temporary_app"
done
"$lsregister" -f "$target"
if [ "${1:-}" = --authorize-keychain ]; then
  shift
  "$target/Contents/MacOS/poteto" --migrate "$@"
elif [ "$#" -gt 0 ]; then
  "$target/Contents/MacOS/poteto" --migrate "$@"
fi
"$target/Contents/MacOS/poteto" --enable-login
echo "installed $target (login startup enabled)"
