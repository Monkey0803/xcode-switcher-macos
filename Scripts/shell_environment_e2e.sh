#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$script_dir/build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-shell-e2e.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/Bound/Demo.xcodeproj" "$fixture/Empty"
xcode_app="$(env -u DEVELOPER_DIR xcode-select --print-path)"
[[ "$xcode_app" == */Contents/Developer ]]
xcode_app="${xcode_app%/Contents/Developer}"
[[ -n "$xcode_app" && -d "$xcode_app/Contents/Developer" ]]
printf '{"xcode":"%s"}\n' "$xcode_app" > "$fixture/Bound/.xcode-switcher.json"
ln -s "$cli" "$fixture/bin/xcodeswitcher"

bound_output="$("$cli" env "$fixture/Bound")"
[[ "$bound_output" == "export DEVELOPER_DIR='$xcode_app/Contents/Developer'" ]]
[[ "$("$cli" env "$fixture/Empty")" == "unset DEVELOPER_DIR" ]]

before="$(env -u DEVELOPER_DIR xcode-select --print-path)"
PATH="$fixture/bin:$PATH" DEVELOPER_DIR="/custom/original" zsh -fc '
  eval "$(xcodeswitcher shell-init zsh)"
  cd "$1/Bound"
  [[ "$DEVELOPER_DIR" == "$2/Contents/Developer" ]]
  cd "$1/Empty"
  [[ "$DEVELOPER_DIR" == "/custom/original" ]]
' zsh "$fixture" "$xcode_app"
after="$(env -u DEVELOPER_DIR xcode-select --print-path)"
[[ "$before" == "$after" ]]

printf 'Shell environment E2E passed: env resolution, zsh restoration, and global developer path preservation.\n'
