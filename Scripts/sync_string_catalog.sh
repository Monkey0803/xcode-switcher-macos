#!/usr/bin/env bash
#
# Syncs Resources/Localizable.xcstrings with the strings the Swift compiler
# extracted into .stringsdata.
#
# Why this exists: `xcodebuild` emits .stringsdata for every source file, but it
# never merges that back into the source .xcstrings — updating the catalog is an
# Xcode IDE step. `xcstringstool sync` performs the same merge from the command
# line, which keeps the catalog reproducible in CI instead of depending on
# someone opening the project in Xcode.
#
# 用法：sync_string_catalog.sh [derived data path]

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
derived_data="${1:-$script_dir/build/DerivedData}"
catalog="$script_dir/Resources/Localizable.xcstrings"

if [[ ! -f "$catalog" ]]; then
  printf '错误：找不到 %s\n' "$catalog" >&2
  exit 1
fi

stringsdata=()
while IFS= read -r file; do
  stringsdata+=("$file")
done < <(/usr/bin/find "$derived_data" \
  \( -path "*/XcodeSwitcher.build/*/XcodeSwitcher.build/Objects-normal/*" \
  -o -path "*/XcodeSwitcher.build/*/xcodeswitcher-cli.build/Objects-normal/*" \) \
  -name "*.stringsdata" -type f 2>/dev/null | sort)

if [[ ${#stringsdata[@]} -eq 0 ]]; then
  printf '错误：%s 下没有找到 app target 的 .stringsdata，请先构建 app target。\n' "$derived_data" >&2
  exit 1
fi

/usr/bin/xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"

count="$(/usr/bin/xcrun xcstringstool print "$catalog" 2>/dev/null | /usr/bin/grep -c . || true)"
printf '已合并 %d 个 .stringsdata，%s 现在包含 %s 个字符串键。\n' \
  "${#stringsdata[@]}" "${catalog#"$script_dir"/}" "${count:-?}"
