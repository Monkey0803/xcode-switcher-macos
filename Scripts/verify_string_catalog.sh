#!/usr/bin/env bash
#
# Checks Resources/Localizable.xcstrings:
#   * every translation keeps the same format specifiers as its key
#   * every translation keeps the same number of line breaks
#   * reports how many keys are translated per language
#
# Exits non-zero on the first structural problem so it can gate CI.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
catalog="$script_dir/Resources/Localizable.xcstrings"

if [[ ! -f "$catalog" ]]; then
  printf '错误：找不到 %s\n' "$catalog" >&2
  exit 1
fi

/usr/bin/python3 - "$catalog" <<'PY'
import collections
import json
import pathlib
import re
import sys

catalog = pathlib.Path(sys.argv[1])
data = json.loads(catalog.read_text(encoding="utf-8"))
strings = data.get("strings", {})
source_language = data.get("sourceLanguage", "?")

# Matches by conversion type only: `xcstringstool sync` rewrites the source
# language of multi-placeholder keys with positional specifiers (%1$@), which is
# equivalent to %@ for parity purposes.
SPECIFIER = re.compile(r"%(?:\d+\$)?(lld|ld|d|@|s|f)")
# Anything percentage-shaped that SPECIFIER does not cover is suspicious rather
# than silently ignored (a literal "%%" is allowed).
LEFTOVER = re.compile(r"%(?:\d+\$)?(?:ll|l|h|z|t|j)?[A-Za-z@]")

problems: list[str] = []
translated = collections.Counter()
languages = sorted(
    {lang for entry in strings.values() for lang in entry.get("localizations", {})}
)

for key, entry in strings.items():
    if entry.get("extractionState") == "stale":
        problems.append(f"条目已标记为 stale，应从 catalog 中删除：{key!r}")
    key_specifiers = collections.Counter(SPECIFIER.findall(key))
    key_newlines = key.count("\n")
    for leftover in LEFTOVER.findall(key):
        if not SPECIFIER.fullmatch(leftover):
            problems.append(f"源字符串含未识别的格式说明符 {leftover!r}：{key!r}")

    for language, localization in entry.get("localizations", {}).items():
        # An entry is either a plain stringUnit or a plural variation set
        # (catalog entries for countable strings must vary by language plural rules).
        if "variations" in localization:
            plurals = localization["variations"].get("plural", {})
            if not plurals:
                problems.append(f"{language} 的 variations 中缺少 plural：{key!r}")
                continue
            if language == "en" and not {"one", "other"} <= set(plurals):
                problems.append(f"{language} 的英文复数需要 one 与 other：{key!r}")
            units = [(name, plural.get("stringUnit")) for name, plural in plurals.items()]
        else:
            units = [(language, localization.get("stringUnit"))]

        for variant, unit in units:
            if unit is None:
                problems.append(f"{language} 的变体 {variant} 缺少 stringUnit：{key!r}")
                continue
            value = unit.get("value", "")
            translated[language] += 1
            # "new" is legitimate for the source language (the sync tool emits it
            # when it rewrites multi-placeholder keys with positional specifiers);
            # a target language must be fully translated.
            allowed_states = {"translated", "new"} if language == source_language else {"translated"}
            if unit.get("state") not in allowed_states:
                problems.append(f"{language}/{variant} 的状态为 {unit.get('state')!r}：{key!r}")

            value_specifiers = collections.Counter(SPECIFIER.findall(value))
            if key_specifiers != value_specifiers:
                problems.append(
                    f"{language}/{variant} 占位符不一致：{key!r} {dict(key_specifiers)} → {value!r} {dict(value_specifiers)}"
                )
            if value.count("\n") != key_newlines:
                problems.append(
                    f"{language}/{variant} 换行数量不一致（{key_newlines} → {value.count(chr(10))}）：{key!r}"
                )
            if not value.strip():
                problems.append(f"{language}/{variant} 的译文为空：{key!r}")

print(f"源语言 {source_language}，共 {len(strings)} 个键")
for language in languages:
    print(f"  {language}: 已翻译 {translated[language]} 条，其余回退到源语言")

if problems:
    print(f"\n发现 {len(problems)} 个问题：", file=sys.stderr)
    for problem in problems[:40]:
        print(f"  - {problem}", file=sys.stderr)
    if len(problems) > 40:
        print(f"  … 另有 {len(problems) - 40} 个", file=sys.stderr)
    sys.exit(1)

print("\nString Catalog 结构校验通过。")
PY
