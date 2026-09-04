#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
app_bundle="$script_dir/build/Xcode Switcher.app"
executable="$app_bundle/Contents/MacOS/XcodeSwitcherApp"

cd "$script_dir"
/usr/bin/xcrun swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
"$script_dir/build_app.sh"
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
/usr/bin/lipo "$executable" -verify_arch arm64 x86_64
/usr/bin/lipo "$app_bundle/Contents/MacOS/xcodeswitcher" -verify_arch arm64 x86_64
/usr/bin/xcrun vtool -show-build "$executable" | /usr/bin/grep -q "minos 13.0"
/usr/bin/otool -L "$executable" | /usr/bin/grep -q "@rpath/Sparkle.framework/Versions/B/Sparkle"
/bin/test -x "$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
"$app_bundle/Contents/MacOS/xcodeswitcher" list | /usr/bin/grep -q "Xcode"
"$app_bundle/Contents/MacOS/xcodeswitcher" current | /usr/bin/grep -q "developer="
/bin/bash -n \
  "$script_dir/build_app.sh" \
  "$script_dir/build_release.sh" \
  "$script_dir/build_local_release.sh" \
  "$script_dir/Scripts/release_preflight.sh" \
  "$script_dir/Scripts/sign_bundle.sh"

if release_preflight_output="$(
  /usr/bin/env -i PATH=/usr/bin:/bin \
    /bin/bash "$script_dir/build_release.sh" --preflight 2>&1
)"; then
  printf 'Release preflight unexpectedly succeeded without credentials.\n' >&2
  exit 1
fi
for variable_name in DEVELOPER_ID_APPLICATION NOTARYTOOL_PROFILE SU_FEED_URL SPARKLE_PUBLIC_KEY; do
  /usr/bin/grep -q "$variable_name" <<<"$release_preflight_output"
done

"$executable" >"${TMPDIR:-/tmp}/xcode-switcher-smoke.log" 2>&1 &
app_pid=$!
cleanup() {
  if /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill -TERM "$app_pid" 2>/dev/null || true
  fi
  wait "$app_pid" 2>/dev/null || true
}
trap cleanup EXIT
/bin/sleep 2
/bin/kill -0 "$app_pid"

printf 'Smoke test passed: unit tests, universal app/CLI, Sparkle link, plist, signature, scripts, and packaged launch.\n'
