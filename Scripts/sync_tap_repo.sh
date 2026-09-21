#!/usr/bin/env bash
#
# Copies Casks/xcode-switcher.rb and Formula/xcode-switcher.rb into a clone of the
# Homebrew tap, and rewrites the tap README's two version references, so that
# `brew install --cask xcode-switcher` serves the version this repository just released.
#
# It deliberately does **not** commit or push: pushing to a second public repository is a
# decision, not a side effect. The diff is printed, together with the exact commands to
# finish the job.
#
# Why this exists: the tap is a separate repository with no automation, and the two
# releases before 2.1.0 were never synced at all — `brew install --cask xcode-switcher`
# served 1.5.1 while the README advertised 2.0.0, and the stale cask still said
# `depends_on macos: :ventura` for an app that had required macOS 15 since 2.0.0.
#
# 用法：sync_tap_repo.sh [tap-clone-path]
#   路径不存在时会先克隆 tap（默认 ../homebrew-xcode-switcher）。
#
set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
tap_repository="https://github.com/Monkey0803/homebrew-xcode-switcher.git"
tap_path="${1:-$script_dir/../homebrew-xcode-switcher}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$script_dir/Resources/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$script_dir/Resources/Info.plist")"

if [[ ! -d "$tap_path/.git" ]]; then
  printf 'tap 克隆不存在，正在克隆到 %s\n' "$tap_path"
  /usr/bin/git clone "$tap_repository" "$tap_path"
fi

if [[ -n "$(/usr/bin/git -C "$tap_path" status --porcelain)" ]]; then
  printf '错误：%s 有未提交的改动，请先处理（同步前需要是一棵干净的树）。\n' "$tap_path" >&2
  exit 1
fi

for file in Casks/xcode-switcher.rb Formula/xcode-switcher.rb; do
  if [[ ! -f "$tap_path/$file" ]]; then
    printf '错误：%s 里没有 %s，它看起来不是那个 tap 仓库。\n' "$tap_path" "$file" >&2
    exit 1
  fi
  /bin/cp "$script_dir/$file" "$tap_path/$file"
done

# The tap README quotes the current version twice; leaving it behind is how it kept
# advertising 1.5.1. Both spots are rewritten from the version in the cask just copied.
/usr/bin/python3 - "$tap_path/README.md" "$version" "$build" <<'PY'
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1])
version, build = sys.argv[2], sys.argv[3]
text = readme.read_text(encoding="utf-8")
text, quoted = re.subn(r"currently \*\*v[0-9.]+\*\*", f"currently **v{version}**", text)
text, sample = re.subn(r'version "\d+\.\d+\.\d+,\d+"', f'version "{version},{build}"', text)
readme.write_text(text, encoding="utf-8")
print(f"README 里的版本引用已改写 {quoted} 处（当前版本）+ {sample} 处（cask 片段）")
PY

printf '\n=== %s 的待提交差异 ===\n' "$tap_path"
/usr/bin/git -C "$tap_path" --no-pager diff --stat
/usr/bin/git -C "$tap_path" --no-pager diff -- Casks/xcode-switcher.rb Formula/xcode-switcher.rb README.md | head -40

cat <<EOS

=== 接下来（脚本不代劳） ===
  cd "$tap_path"
  git -c user.name='Monkey0803' \\
      -c user.email='11564933+Monkey0803@users.noreply.github.com' \\
      commit -m "chore(cask): 升到 v$version"
  git push origin main

提交身份必须用上面的 noreply 地址：该仓库开启了邮箱隐私限制，用本机
hu_1987@126.com 提交会被 GitHub 拒收（push declined due to email privacy
restrictions），实测于 2026-09-21。

推完核对一遍（brew 读的就是这个仓库）：

  gh api repos/Monkey0803/homebrew-xcode-switcher/contents/Casks/xcode-switcher.rb \\
    --jq '.content' | base64 -d | grep -E 'version "|sha256 "|depends_on macos'
EOS
