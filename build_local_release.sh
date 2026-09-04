#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
app_bundle="$script_dir/build/Xcode Switcher.app"
release_dir="$script_dir/release/local"

"$script_dir/build_app.sh"
/usr/bin/codesign --verify --deep --strict "$app_bundle"
/usr/bin/lipo "$app_bundle/Contents/MacOS/XcodeSwitcherApp" -verify_arch arm64 x86_64
/usr/bin/lipo "$app_bundle/Contents/MacOS/xcodeswitcher" -verify_arch arm64 x86_64

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")"
/bin/mkdir -p "$release_dir"

archive_path="$release_dir/Xcode-Switcher-$version-$build_number-local.zip"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path"

dmg_staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-local-dmg.XXXXXX")"
cleanup() {
  /bin/rm -rf "$dmg_staging"
}
trap cleanup EXIT
/usr/bin/ditto "$app_bundle" "$dmg_staging/Xcode Switcher.app"
/bin/ln -s /Applications "$dmg_staging/Applications"
dmg_path="$release_dir/Xcode-Switcher-$version-$build_number-local.dmg"
/usr/bin/hdiutil create -volname "Xcode Switcher" -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"

printf '本地直接分发产物（未经过 Apple 公证，可能显示 Gatekeeper 提示）：\n%s\n%s\n' "$archive_path" "$dmg_path"
