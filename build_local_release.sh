#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
release_dir="$script_dir/release/local"
archive_app="$script_dir/build/XcodeSwitcher.xcarchive/Products/Applications/Xcode Switcher.app"

"$script_dir/Scripts/archive_app.sh"

/usr/bin/codesign --verify --deep --strict "$archive_app"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$archive_app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$archive_app/Contents/Info.plist")"
/bin/mkdir -p "$release_dir"

archive_path="$release_dir/Xcode-Switcher-$version-$build_number-local.zip"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$archive_app" "$archive_path"

dmg_staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-local-dmg.XXXXXX")"
cleanup() {
  /bin/rm -rf "$dmg_staging"
}
trap cleanup EXIT
/usr/bin/ditto "$archive_app" "$dmg_staging/Xcode Switcher.app"
/bin/ln -s /Applications "$dmg_staging/Applications"
dmg_path="$release_dir/Xcode-Switcher-$version-$build_number-local.dmg"
/usr/bin/hdiutil create -volname "Xcode Switcher" -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"

printf '本地直接分发产物（未经过 Apple 公证，可能显示 Gatekeeper 提示）：\n%s\n%s\n' "$archive_path" "$dmg_path"