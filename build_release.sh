#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
archive_path="$script_dir/build/XcodeSwitcher.xcarchive"
archive_app="$archive_path/Products/Applications/Xcode Switcher.app"
export_dir="$script_dir/build/exported"
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

# 1) Archive with xcodebuild instead of assembling the bundle by hand.
"$script_dir/Scripts/archive_app.sh" "$archive_path"

# 2) The Sparkle feed settings live outside the repository, so they are injected
#    into the archived app; `-exportArchive` re-signs the bundle afterwards and
#    therefore covers the edit.
if [[ -n "${SU_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  for entry in "SUFeedURL:$SU_FEED_URL" "SUPublicEDKey:$SPARKLE_PUBLIC_KEY"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$archive_app/Contents/Info.plist" 2>/dev/null ||
      /usr/libexec/PlistBuddy -c "Set :$key $value" "$archive_app/Contents/Info.plist"
  done
fi

# 3) Export a Developer ID bundle. The team ID is taken from the signing identity
#    so no extra configuration is needed.
team_id="$(printf '%s' "$DEVELOPER_ID_APPLICATION" | /usr/bin/sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
if [[ -z "$team_id" ]]; then
  printf '错误：无法从签名身份中解析 Team ID：%s\n' "$DEVELOPER_ID_APPLICATION" >&2
  exit 1
fi

export_options="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/xcode-switcher-export.XXXXXX.plist")"
cleanup_export_options() {
  /bin/rm -f "$export_options"
}
trap cleanup_export_options EXIT

/usr/bin/plutil -create xml1 "$export_options"
/usr/bin/plutil -insert method -string developer-id "$export_options"
/usr/bin/plutil -insert destination -string export "$export_options"
/usr/bin/plutil -insert signingStyle -string manual "$export_options"
/usr/bin/plutil -insert signingCertificate -string "$DEVELOPER_ID_APPLICATION" "$export_options"
/usr/bin/plutil -insert teamID -string "$team_id" "$export_options"

/bin/rm -rf "$export_dir"
/usr/bin/xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$export_dir"

# Discover the exported bundle instead of assuming its name: Xcode derives it from
# the product name, and a wrong assumption would only surface at release time.
app_bundle="$(/usr/bin/find "$export_dir" -maxdepth 1 -name "*.app" -print -quit)"
if [[ ! -d "$app_bundle" ]]; then
  printf '错误：导出目录中没有 .app：%s\n' "$export_dir" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")"
archive_name="Xcode-Switcher-$version-$build_number.zip"
archive_path_zip="$updates_dir/$archive_name"

/bin/mkdir -p "$updates_dir"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path_zip"
/usr/bin/xcrun notarytool submit "$archive_path_zip" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app_bundle"
/bin/rm -f "$archive_path_zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path_zip"

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
generate_appcast_arguments=(
  -o "$release_dir/appcast.xml"
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX"
)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  generate_appcast_arguments+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi
"$generate_appcast" "${generate_appcast_arguments[@]}" "$updates_dir"

printf '正式分发产物：\n%s\n%s\n%s\n' "$archive_path_zip" "$dmg_path" "$release_dir/appcast.xml"