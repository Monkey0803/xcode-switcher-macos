#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
app_bundle="$script_dir/build/Xcode Switcher.app"
macos_dir="$app_bundle/Contents/MacOS"
resources_dir="$app_bundle/Contents/Resources"
frameworks_dir="$app_bundle/Contents/Frameworks"
iconset_dir="$script_dir/build/AppIcon.iconset"
app_arm64="$script_dir/build/XcodeSwitcher-app-arm64"
app_x86_64="$script_dir/build/XcodeSwitcher-app-x86_64"
cli_arm64="$script_dir/build/xcodeswitcher-cli-arm64"
cli_x86_64="$script_dir/build/xcodeswitcher-cli-x86_64"

mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"
cp "$script_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
/bin/rm -f "$macos_dir/XcodeSwitcher"

/usr/bin/xcrun swift package resolve
sparkle_framework="$(/usr/bin/find "$script_dir/.build/artifacts" -type d -name Sparkle.framework -print -quit)"
if [[ -z "$sparkle_framework" ]]; then
  printf '错误：未找到 Swift Package Manager 下载的 Sparkle.framework。\n' >&2
  exit 1
fi
/usr/bin/ditto "$sparkle_framework" "$frameworks_dir/Sparkle.framework"
sparkle_parent="$(dirname "$sparkle_framework")"

if [[ -n "${SU_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SU_FEED_URL" "$app_bundle/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SU_FEED_URL" "$app_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$app_bundle/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" "$app_bundle/Contents/Info.plist"
fi

rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
/usr/bin/sips -s format png "$script_dir/Resources/AppIcon.svg" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
for size in 16 32 64 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$iconset_dir/icon_512x512@2x.png" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
done
cp "$iconset_dir/icon_32x32.png" "$iconset_dir/icon_16x16@2x.png"
cp "$iconset_dir/icon_64x64.png" "$iconset_dir/icon_32x32@2x.png"
cp "$iconset_dir/icon_256x256.png" "$iconset_dir/icon_128x128@2x.png"
cp "$iconset_dir/icon_512x512.png" "$iconset_dir/icon_256x256@2x.png"
/usr/bin/iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"

menu_icon_source="$script_dir/build/MenuBarIcon-source.png"
/usr/bin/sips -s format png "$script_dir/Resources/MenuBarIcon.svg" --out "$menu_icon_source" >/dev/null
/usr/bin/sips -z 36 36 "$menu_icon_source" --out "$resources_dir/MenuBarIcon.png" >/dev/null

for architecture in arm64 x86_64; do
  app_output="$script_dir/build/XcodeSwitcher-app-$architecture"
  cli_output="$script_dir/build/xcodeswitcher-cli-$architecture"
  /usr/bin/xcrun swiftc -O \
    -parse-as-library \
    -target "$architecture-apple-macosx13.0" \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -framework SwiftUI \
    -framework AppKit \
    -framework Security \
    -F "$sparkle_parent" \
    -framework Sparkle \
    -Xlinker -needed_framework \
    -Xlinker Sparkle \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    "$script_dir"/Sources/*.swift \
    -o "$app_output"

  /usr/bin/xcrun swiftc -O \
    -parse-as-library \
    -target "$architecture-apple-macosx13.0" \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -framework AppKit \
    -framework Security \
    "$script_dir/Sources/Models.swift" \
    "$script_dir/Sources/ProjectMatching.swift" \
    "$script_dir/Sources/Services.swift" \
    "$script_dir/Sources/EnvironmentDoctor.swift" \
    "$script_dir/SourcesCLI/main.swift" \
    -o "$cli_output"
done

/usr/bin/lipo -create "$app_arm64" "$app_x86_64" -output "$macos_dir/XcodeSwitcherApp"
/usr/bin/lipo -create "$cli_arm64" "$cli_x86_64" -output "$macos_dir/xcodeswitcher"

"$script_dir/Scripts/sign_bundle.sh" "$app_bundle" "-"
printf '已构建：%s\n' "$app_bundle"
