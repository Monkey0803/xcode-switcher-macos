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

candidates=()
while IFS= read -r candidate; do
  candidates+=("$candidate")
done < <(/usr/bin/find "$derived_data" \
  \( -path "*/XcodeSwitcher.build/*/XcodeSwitcher.build/Objects-normal/*" \
  -o -path "*/XcodeSwitcher.build/*/XcodeSwitcherKit.build/Objects-normal/*" \
  -o -path "*/XcodeSwitcher.build/*/xcodeswitcher-cli.build/Objects-normal/*" \) \
  -name "*.stringsdata" -type f 2>/dev/null | sort)

if [[ ${#candidates[@]} -eq 0 ]]; then
  printf '错误：%s 下没有找到 app target 的 .stringsdata，请先构建 app target。\n' "$derived_data" >&2
  exit 1
fi

# A .stringsdata left by an earlier build of a file that has since changed would
# resurrect keys that no longer exist, or — right after they are removed — strip keys
# that still do, so stale ones are skipped loudly. Whether one *is* stale is a content
# question, not an mtime one: a file whose extracted strings did not change is reused
# from the build cache without being rewritten, so its mtime goes stale while its
# content stays correct, and a `git checkout`/`stash`/`cp` moves the source's mtime the
# other way without changing anything. Scripts/stringsdata_freshness.py reports which
# files still line up and explains every one it drops.
stringsdata=()
while IFS= read -r file; do
  stringsdata+=("$file")
done < <(/usr/bin/python3 "$script_dir/Scripts/stringsdata_freshness.py" "${candidates[@]}")

if [[ ${#stringsdata[@]} -eq 0 ]]; then
  printf '错误：所有 .stringsdata 都与源码对不上，请重新构建 app target。\n' >&2
  exit 1
fi

/usr/bin/xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"

# `xcstringstool sync` re-serialises the *whole* file in its own JSON style, and that
# style moves between Xcode releases: Xcode 26.3 writes `"key" : value` and drops the
# trailing newline, while the committed catalog uses `"key": value` with one. The CI
# gate (`Verify the string catalog is in sync with the sources`) diffs this file right
# after running this script, so a style-only rewrite would fail a build whose strings
# are in fact correct. Normalise back to the committed style — and sort the keys, so
# the result does not depend on merge order — then report the real key count, which
# `xcstringstool print | grep -c .` over-reported (it counted structure lines too).
key_count="$(/usr/bin/python3 - "$catalog" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
strings = dict(sorted(data.get("strings", {}).items()))
data["strings"] = strings
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(len(strings))
PY
)"

printf '已合并 %d 个 .stringsdata，%s 现在包含 %s 个字符串键。\n' \
  "${#stringsdata[@]}" "${catalog#"$script_dir"/}" "$key_count"
