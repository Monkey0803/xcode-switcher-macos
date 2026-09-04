#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf '用法：%s <app bundle> <code signing identity>\n' "$0" >&2
  exit 2
fi

app_bundle="$1"
signing_identity="$2"
sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle_framework/Versions/B"

if [[ ! -d "$app_bundle" || ! -d "$sparkle_framework" ]]; then
  printf '错误：App 或 Sparkle.framework 不存在。\n' >&2
  exit 1
fi

sign_args=(--force --sign "$signing_identity" --options runtime)
if [[ "$signing_identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi
app_sign_args=("${sign_args[@]}")
if [[ "$signing_identity" == "-" ]]; then
  script_dir="$(cd "$(dirname "$0")" && pwd -P)"
  app_sign_args+=(--entitlements "$script_dir/../Resources/Debug.entitlements")
fi

/usr/bin/codesign "${sign_args[@]}" "$sparkle_version/XPCServices/Installer.xpc"
/usr/bin/codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
/usr/bin/codesign "${sign_args[@]}" "$sparkle_version/Autoupdate"
/usr/bin/codesign "${sign_args[@]}" "$sparkle_version/Updater.app"
/usr/bin/codesign "${sign_args[@]}" "$sparkle_framework"
/usr/bin/codesign "${sign_args[@]}" "$app_bundle/Contents/MacOS/xcodeswitcher"
/usr/bin/codesign "${app_sign_args[@]}" "$app_bundle"
