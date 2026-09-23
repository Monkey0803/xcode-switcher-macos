#!/usr/bin/env bash
#
# Runs the packaged CLI and checks the contract a shell script consuming it depends
# on: the exit statuses, the `--json` error shape, and which stream the error lands on.
#
# Why this is a shell test and not XCTest: the behaviour under test lives at the
# process boundary — `exit`, stderr, the JSON printed to it — which nothing inside the
# test bundle can observe. `Tests/CLIOptionsTests.swift` covers argument parsing; this
# covers what the caller actually sees.
#
# The contract is documented in README.md under 「命令行」:
#   0   success
#   1   the command ran and did not succeed
#   2   `doctor` reporting a severe finding (its own 0/1/2 result scale)
#   64  the command line itself was wrong (EX_USAGE)

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cli="$script_dir/build/Xcode Switcher.app/Contents/MacOS/xcodeswitcher"

if [[ ! -x "$cli" ]]; then
  printf 'CLI 未构建或不可执行：%s\n先运行 ./build_app.sh。\n' "$cli" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/xcode-switcher-cli-e2e.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# run <expected status> <args...>
# Sets $stdout and $stderr, and fails the script when the status is not the expected
# one — printing both streams, because "it returned 1" is useless without the message.
run() {
  local expected="$1"; shift
  local status=0
  set +e
  stdout="$("$cli" "$@" 2>"$work/stderr")"
  status=$?
  set -e
  stderr="$(cat "$work/stderr")"
  if [[ "$status" -ne "$expected" ]]; then
    printf '退出码不符：期望 %s，实际 %s\n命令：xcodeswitcher %s\n标准输出：\n%s\n标准错误：\n%s\n' \
      "$expected" "$status" "$*" "$stdout" "$stderr" >&2
    exit 1
  fi
}

expect_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '%s 未包含 %s：\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

# --- 只读命令成功，且不改变系统状态 ---
before_developer_dir="$(env -u DEVELOPER_DIR xcode-select --print-path)"

run 0 list
expect_contains "$stdout" "Xcode" "list"
run 0 --json list
expect_contains "$stdout" '"name"' "--json list"

run 0 current
expect_contains "$stdout" "developer=" "current"
run 0 --json current
expect_contains "$stdout" '"developer"' "--json current"

run 0 version
run 0 --help
run 0
expect_contains "$stdout" "用法" "无参数时打印帮助"

# --- 用法错误：64，JSON 走标准错误 ---
run 64 definitely-not-a-command
expect_contains "$stderr" "未知命令" "未知命令"
run 64 --json definitely-not-a-command
expect_contains "$stderr" '"code":"usage"' "--json 未知命令"
if [[ -n "$stdout" ]]; then
  printf '用法错误的 JSON 应写在标准错误，而不是标准输出：\n%s\n' "$stdout" >&2
  exit 1
fi
run 64 use
run 64 resolve /tmp/not-a-project.txt
run 64 completions powershell

# --- 运行期失败：1 ---
run 1 use 99.9
run 1 --json use 99.9
expect_contains "$stderr" '"code":"failed"' "--json 未找到 Xcode"

# --- uninstall：拒绝要按规则来，预览不能动任何东西 ---
run 64 uninstall
run 1 uninstall --dry-run 99.9

# 系统默认的 Xcode 必须被拒绝，而不是被移走：这是这个命令最危险的误用。
active_version="$(/usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["version"] if data.get("active") else "")
' <<<"$("$cli" --json current)")"
if [[ -n "$active_version" ]]; then
  run 1 --json uninstall --dry-run "$active_version"
  expect_contains "$stderr" '"code":"failed"' "--json uninstall 拒绝系统默认版本"
fi

# 预览一个真的可以被移除的版本——既不是系统默认，也没有被项目绑定。CI 上通常
# 只有一台 Xcode（也就是默认那台），这时整段跳过。
spare_version="$(/usr/bin/python3 - "$cli" <<'SPARE'
import json, pathlib, subprocess, sys

cli = sys.argv[1]


def out(args):
    return json.loads(subprocess.run([cli, *args], capture_output=True, text=True).stdout)


try:
    installs = out(["--json", "list"])
    active = out(["--json", "current"]).get("developer")
except Exception:
    sys.exit(0)

bound = set()
try:
    config = json.loads(
        (pathlib.Path.home() / "Library/Application Support/XcodeSwitcher/configuration.json").read_text()
    )
    bound = {p["xcodeID"] for p in config.get("projects", []) if p.get("xcodeID")}
except Exception:
    pass

for item in installs:
    if item.get("developer") != active and item.get("app") not in bound:
        print(item["version"])
        break
SPARE
)"
if [[ -n "$spare_version" ]]; then
  run 0 uninstall --dry-run "$spare_version"
  expect_contains "$stdout" "[dry-run]" "uninstall --dry-run"
  run 0 --json uninstall --dry-run "$spare_version"
  expect_contains "$stdout" '"performed" : false' "--json uninstall --dry-run"
fi

# --- dry-run 只解析，不切换 ---
# 这里的版本号不可能存在，所以用 list 里真实存在的一个。
installation_version="$(/usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data[0]["version"])
' <<<"$("$cli" --json list)")"
run 0 use --dry-run "$installation_version"
expect_contains "$stdout" "[dry-run]" "use --dry-run"

after_developer_dir="$(env -u DEVELOPER_DIR xcode-select --print-path)"
if [[ "$before_developer_dir" != "$after_developer_dir" ]]; then
  printf 'CLI 改变了全局 Developer 目录：%s -> %s\n' \
    "$before_developer_dir" "$after_developer_dir" >&2
  exit 1
fi

# --- doctor 用自己的结果等级，从不返回 64 ---
doctor_status=0
set +e
"$cli" doctor >"$work/doctor.out" 2>&1
doctor_status=$?
set -e
case "$doctor_status" in
  0 | 1 | 2) ;;
  *)
    printf 'doctor 应返回 0/1/2 的结果等级，实际 %s：\n%s\n' "$doctor_status" "$(cat "$work/doctor.out")" >&2
    exit 1
    ;;
esac

printf 'CLI 契约 E2E 通过：只读命令、退出码 0/1/2/64、--json 错误结构与标准错误输出、uninstall 的拒绝规则、dry-run 不改变全局开发者目录。\n'
