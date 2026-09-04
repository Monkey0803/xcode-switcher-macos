#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
app_bundle="$script_dir/build/Xcode Switcher.app"
release_dir="$script_dir/release"
updates_dir="$release_dir/updates"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--preflight" ) ]]; then
  printf '用法：%s [--preflight]\n' "$0" >&2
  exit 2
fi

"$script_dir/Scripts/release_preflight.sh"
if [[ "${1:-}" == "--preflight" ]]; then
  exit 0
fi

SU_FEED_URL="$SU_FEED_URL" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" "$script_dir/build_app.sh"
"$script_dir/Scripts/sign_bundle.sh" "$app_bundle" "$DEVELOPER_ID_APPLICATION"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")"
archive_name="Xcode-Switcher-$version-$build_number.zip"
archive_path="$updates_dir/$archive_name"

/bin/mkdir -p "$updates_dir"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path"
/usr/bin/xcrun notarytool submit "$archive_path" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app_bundle"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path"

dmg_staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-dmg.XXXXXX")"
cleanup() {
  /bin/rm -rf "$dmg_staging"
}
trap cleanup EXIT
/usr/bin/ditto "$app_bundle" "$dmg_staging/Xcode Switcher.app"
/bin/ln -s /Applications "$dmg_staging/Applications"
dmg_path="$release_dir/Xcode-Switcher-$version-$build_number.dmg"
/usr/bin/hdiutil create -volname "Xcode Switcher" -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"
/usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg_path"
/usr/bin/xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_bundle"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

generate_appcast="$script_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
"$generate_appcast" -o "$release_dir/appcast.xml" "$updates_dir"

printf '正式分发产物：\n%s\n%s\n%s\n' "$archive_path" "$dmg_path" "$release_dir/appcast.xml"
