#!/usr/bin/env bash
#
# Archives the app with `xcodebuild archive`, re-signs it, and validates the
# result — replacing the hand-assembled bundle that build_app.sh produces for
# release builds.
#
# 用法：archive_app.sh [archive path]
#
# 环境变量：
#   XCODE_DERIVED_DATA  归档用的 DerivedData 目录（默认 build/ReleaseDerivedData）
#   ARCHIVE_CONFIGURATION  默认 Release
#   ARCHIVE_SKIP_LAUNCH_CHECK  设为 1 可跳过启动校验（仅用于确实无法启动 GUI 的环境）

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
archive_path="${1:-$script_dir/build/XcodeSwitcher.xcarchive}"
derived_data="${XCODE_DERIVED_DATA:-$script_dir/build/ReleaseDerivedData}"
configuration="${ARCHIVE_CONFIGURATION:-Release}"

fail() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

/bin/rm -rf "$archive_path"

/usr/bin/xcodebuild \
  -project "$script_dir/XcodeSwitcher.xcodeproj" \
  -scheme "Xcode Switcher" \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data" \
  -archivePath "$archive_path" \
  archive

app="$archive_path/Products/Applications/Xcode Switcher.app"

[[ -d "$app" ]] || fail "归档中缺少 $app"

# Xcode's own ad-hoc signing is not enough for this bundle. The v1.4.0 release
# shipped an archive-signed app that passed `codesign --verify --deep --strict`
# and still died at launch:
#
#   dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   ... mapping process and mapped file (non-platform) have different Team IDs
#
# Library Validation (enabled by the hardened runtime, which the project turns on)
# then rejects the embedded framework. Re-signing every nested component in order
# — as the script build path has always done — fixes it. `build_release.sh` runs
# `-exportArchive` afterwards, which re-signs with the Developer ID identity and
# supersedes this ad-hoc pass.
"$script_dir/Scripts/sign_bundle.sh" "$app" "-" >/dev/null

# The bundle layout is part of the contract: build_app.sh produces the same
# shape, and the zsh integration plus the smoke test depend on the CLI path.
[[ -x "$app/Contents/MacOS/XcodeSwitcherApp" ]] || fail "缺少主可执行文件"
[[ -x "$app/Contents/MacOS/xcodeswitcher" ]] || fail "缺少内嵌 CLI"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "缺少 Sparkle.framework"
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "缺少 AppIcon.icns"
[[ -f "$app/Contents/Resources/MenuBarIcon.png" ]] || fail "缺少 MenuBarIcon.png"

/usr/bin/lipo "$app/Contents/MacOS/XcodeSwitcherApp" -verify_arch arm64 >/dev/null || fail "主可执行文件不是 arm64"
/usr/bin/lipo "$app/Contents/MacOS/xcodeswitcher" -verify_arch arm64 >/dev/null || fail "CLI 不是 arm64"

/usr/bin/codesign --verify --deep --strict "$app" || fail "签名校验失败"

# Launching is part of the contract, not an extra. Structural checks and
# `codesign --verify` ALL passed on the v1.4.0 artifact while the app could not
# start, so anything that ships must survive a real launch here.
if [[ "${ARCHIVE_SKIP_LAUNCH_CHECK:-0}" != "1" ]]; then
  launch_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/xcode-switcher-launch.XXXXXX")"
  "$app/Contents/MacOS/XcodeSwitcherApp" >"$launch_log" 2>&1 &
  launch_pid=$!
  sleep 3
  if /bin/kill -0 "$launch_pid" 2>/dev/null; then
    /bin/kill "$launch_pid" 2>/dev/null || true
    /bin/rm -f "$launch_log"
  else
    printf '错误：归档中的 app 启动即退出。输出：\n' >&2
    /bin/cat "$launch_log" >&2
    /bin/rm -f "$launch_log"
    exit 1
  fi
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

printf '已归档并验证 Xcode Switcher %s (%s)：\n%s\n' "$version" "$build_number" "$archive_path"