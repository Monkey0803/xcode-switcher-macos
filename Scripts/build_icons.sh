#!/usr/bin/env bash
#
# Generates the app icon (.icns) and the menu bar icon (.png) from the SVG
# sources. Shared by build_app.sh and the Xcode "Generate icons" build phase so
# both build paths produce the same bundle contents.
#
# 用法：build_icons.sh <resources dir> <output resources dir>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf '用法：%s <resources dir> <output resources dir>\n' "$0" >&2
  exit 2
fi

resources_dir="$1"
output_dir="$2"

if [[ ! -f "$resources_dir/AppIcon.svg" || ! -f "$resources_dir/MenuBarIcon.svg" ]]; then
  printf '错误：%s 下缺少 AppIcon.svg 或 MenuBarIcon.svg。\n' "$resources_dir" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-icons.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

iconset_dir="$work_dir/AppIcon.iconset"
mkdir -p "$iconset_dir" "$output_dir"

/usr/bin/sips -s format png "$resources_dir/AppIcon.svg" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
for size in 16 32 64 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$iconset_dir/icon_512x512@2x.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
done
cp "$iconset_dir/icon_32x32.png" "$iconset_dir/icon_16x16@2x.png"
cp "$iconset_dir/icon_64x64.png" "$iconset_dir/icon_32x32@2x.png"
cp "$iconset_dir/icon_256x256.png" "$iconset_dir/icon_128x128@2x.png"
cp "$iconset_dir/icon_512x512.png" "$iconset_dir/icon_256x256@2x.png"
/usr/bin/iconutil -c icns "$iconset_dir" -o "$output_dir/AppIcon.icns"

/usr/bin/sips -s format png "$resources_dir/MenuBarIcon.svg" --out "$work_dir/MenuBarIcon-source.png" >/dev/null
/usr/bin/sips -z 36 36 "$work_dir/MenuBarIcon-source.png" --out "$output_dir/MenuBarIcon.png" >/dev/null

printf '已生成图标：%s/AppIcon.icns 与 %s/MenuBarIcon.png\n' "$output_dir" "$output_dir"
