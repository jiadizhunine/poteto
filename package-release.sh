#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[ "$#" = 2 ] && [ "$1" = --output ] || { echo 'Usage: bash package-release.sh --output DIRECTORY' >&2; exit 1; }
[ -d "$2" ] && [ ! -L "$2" ] || { echo 'Output directory must already exist and not be a symlink' >&2; exit 1; }
output=$(cd "$2" && pwd -P)
work=$(/usr/bin/mktemp -d "$output/.poteto-release.XXXXXXXX")
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then
    if /usr/bin/hdiutil detach "$work/mount" >/dev/null; then mounted=0; else echo "Detach required: $work/mount" >&2; fi
  fi
  if [ "$mounted" = 0 ]; then /bin/rm -rf "$work"; fi
}
trap cleanup EXIT
/bin/bash build.sh --release "$work/poteto.app"
inspect() { /usr/bin/python3 Tools/release_artifact.py "$1" "$PWD"; }
expected=$(inspect "$work/poteto.app")
version=${expected#version=}; version=${version%% *}
name="poteto-v${version}-macos-universal"
zip="$output/$name.zip"
dmg="$output/$name.dmg"
[ ! -e "$zip" ] && [ ! -L "$zip" ] && [ ! -e "$dmg" ] && [ ! -L "$dmg" ] || { echo 'Release artifact already exists' >&2; exit 1; }
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$work/poteto.app" "$work/release.zip"
/bin/mkdir "$work/zip-check"
/usr/bin/ditto -x -k "$work/release.zip" "$work/zip-check"
/usr/bin/python3 Tools/release_artifact.py --root "$work/zip-check" zip
[ "$(inspect "$work/zip-check/poteto.app")" = "$expected" ] || { echo 'ZIP app metadata mismatch' >&2; exit 1; }
/usr/bin/python3 Tools/release_artifact.py --compare "$work/poteto.app" "$work/zip-check/poteto.app"
/bin/mkdir "$work/dmg-root"
/usr/bin/ditto "$work/poteto.app" "$work/dmg-root/poteto.app"
/bin/ln -s /Applications "$work/dmg-root/Applications"
/usr/bin/hdiutil create -quiet -fs HFS+ -volname poteto -srcfolder "$work/dmg-root" -format UDZO "$work/release.dmg"
/usr/bin/hdiutil verify -quiet "$work/release.dmg"
/bin/mkdir "$work/mount"
/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mount" "$work/release.dmg"
mounted=1
/usr/bin/python3 Tools/release_artifact.py --root "$work/mount" dmg
[ "$(inspect "$work/mount/poteto.app")" = "$expected" ] || { echo 'DMG app metadata mismatch' >&2; exit 1; }
/usr/bin/python3 Tools/release_artifact.py --compare "$work/poteto.app" "$work/mount/poteto.app"
/usr/bin/hdiutil detach -quiet "$work/mount"
mounted=0
/bin/ln "$work/release.zip" "$zip" 2>/dev/null || { echo 'Cannot publish ZIP without overwriting' >&2; exit 1; }
if ! /bin/ln "$work/release.dmg" "$dmg" 2>/dev/null; then
  /bin/rm "$zip"
  echo 'Cannot publish DMG without overwriting' >&2
  exit 1
fi
printf 'Created %s\nCreated %s\n' "$zip" "$dmg"
