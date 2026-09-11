#!/usr/bin/env bash
#
# Archives the app with `xcodebuild archive` and validates the result, replacing
# the hand-assembled bundle that build_app.sh produces for release builds.
#
# 用法：archive_app.sh [archive path]
#
# 环境变量：
#   XCODE_DERIVED_DATA  归档用的 DerivedData 目录（默认 build/ReleaseDerivedData）
#   ARCHIVE_CONFIGURATION  默认 Release

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
archive_path="${1:-$script_dir/build/XcodeSwitcher.xcarchive}"
derived_data="${XCODE_DERIVED_DATA:-$script_dir/build/ReleaseDerivedData}"
configuration="${ARCHIVE_CONFIGURATION:-Release}"

/bin/rm -rf "$archive_path"

/usr/bin/xcodebuild \
  -project "$script_dir/XcodeSwitcher.xcodeproj" \
  -scheme "Xcode Switcher" \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data" \
  -archivePath "$archive_path" \
  archive

app="$archive_path/Products/Applications/Xcode Switcher.app"

fail() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

[[ -d "$app" ]] || fail "归档中缺少 $app"

# The bundle layout is part of the contract: build_app.sh produces the same
# shape, and the zsh integration plus the smoke test depend on the CLI path.
[[ -x "$app/Contents/MacOS/XcodeSwitcherApp" ]] || fail "缺少主可执行文件"
[[ -x "$app/Contents/MacOS/xcodeswitcher" ]] || fail "缺少内嵌 CLI"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "缺少 Sparkle.framework"
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "缺少 AppIcon.icns"
[[ -f "$app/Contents/Resources/MenuBarIcon.png" ]] || fail "缺少 MenuBarIcon.png"

/usr/bin/lipo "$app/Contents/MacOS/XcodeSwitcherApp" -verify_arch arm64 >/dev/null || fail "主可执行文件不是 arm64"
/usr/bin/lipo "$app/Contents/MacOS/xcodeswitcher" -verify_arch arm64 >/dev/null || fail "CLI 不是 arm64"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

printf '已归档 Xcode Switcher %s (%s)：\n%s\n' "$version" "$build_number" "$archive_path"