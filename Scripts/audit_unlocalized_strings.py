#!/usr/bin/env python3
"""Fails when user-visible Chinese never entered the String Catalog.

Why this exists: `verify_string_catalog.sh` can only check the entries that ARE in
the catalog, and `sync_string_catalog.sh` only merges what the compiler extracted.
Neither notices a Chinese string written as a plain `String` literal — a status
message, a window title, a field label — which is exactly how about forty strings
stayed Chinese in the English UI until 2026-09-21.

The compiler's own extraction is the source of truth for "this literal is
localizable". A build writes one `.stringsdata` per source file listing every key
with its `startingLine` and `startingColumn`, and the column points at the literal's
**opening quote**. So the check is a set difference: Chinese literals under
`Sources/` and `SourcesCLI/` that the compiler did not extract.

Two details that each cost a round of false results and are easy to get wrong:

* `startingColumn` counts **UTF-8 bytes**, not characters. A column that follows any
  CJK text is inflated by the extra bytes: on
  `.accessibilityLabel(isListCollapsed ? "显示列表" : "隐藏列表")` the second literal
  is at character column 50 and byte column 58, and only 58 matches the compiler.
* A literal can contain interpolations that contain further literals
  (`"…\(list.joined(separator: "、"))…"`), so it cannot be found with a regex — the
  nested quote ends the match early and the remainder shows up as a phantom
  unlocalized string. The scanner below skips interpolations properly.

Usage:
    Scripts/audit_unlocalized_strings.py [derivedDataPath]

The derived-data path defaults to `build/DerivedData`, matching the other scripts,
and a build must have run first — that is where the `.stringsdata` comes from.

An unlocalized string that is deliberately left alone is marked on its own line:

    let glyph = "右⌘"   // unlocalized-audit:ok：键位符号，不是文案

The reason after the marker is required, and the number of waivers is reported
rather than silently applied.
"""

from __future__ import annotations

import bisect
import json
import pathlib
import re
import sys

CJK = re.compile(r"[\u3400-\u9fff]")
WAIVER = re.compile(r"unlocalized-audit:ok\s*[:：]\s*(\S.*)")
SOURCE_DIRECTORIES = ("Sources", "SourcesCLI")


def extracted_positions(derived_data: pathlib.Path) -> dict[str, set[tuple[int, int]]]:
    """Extracted (line, column) per source file."""
    positions: dict[str, set[tuple[int, int]]] = {}
    for path in sorted(derived_data.rglob("*.stringsdata")):
        if "ExtractedAppShortcutsMetadata" in path.name:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        source = data.get("source")
        if not source:
            continue
        keys = positions.setdefault(str(pathlib.Path(source).resolve()), set())
        for entry in data.get("tables", {}).get("Localizable", []):
            location = entry.get("location") or {}
            line, column = location.get("startingLine"), location.get("startingColumn")
            if line and column:
                keys.add((line, column))
    return positions


class _Scanner:
    """Collects every string literal with its own text and its UTF-8 byte column.

    The literal's text is recorded with interpolations removed: the Chinese inside
    `"\(String(localized: "未知命令"))"` belongs to the *inner* literal, and reporting
    the outer one would be a false positive. The inner literal is collected on its own
    when the interpolation is walked, so an unlocalized one is still found.
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.line_starts = [0]
        for match in re.finditer("\n", text):
            self.line_starts.append(match.end())
        self.literals: list[tuple[int, int, str]] = []

    def position(self, index: int) -> tuple[int, int]:
        line = bisect.bisect_right(self.line_starts, index)
        # Byte column: `.stringsdata` records UTF-8 byte offsets, so a character
        # column stops matching the moment the line contains any CJK before the
        # literal.
        prefix = self.text[self.line_starts[line - 1]:index]
        return line, len(prefix.encode("utf-8")) + 1

    def scan_string(self, quote: int, hashes: int = 0) -> int:
        """Scan one literal from its opening quote; returns the index just past it."""
        text, length = self.text, len(self.text)
        delimiter = '"""' if text.startswith('"""', quote) else '"'
        closing = delimiter + "#" * hashes
        own: list[str] = []
        cursor = quote + len(delimiter)
        while cursor < length:
            if hashes == 0:
                if text.startswith("\\(", cursor):
                    cursor = self.scan_interpolation(cursor + 2)
                    own.append("<>")
                    continue
                if text[cursor] == "\\":
                    own.append(text[cursor:cursor + 2])
                    cursor += 2
                    continue
            if text.startswith(closing, cursor):
                self.literals.append((*self.position(quote), "".join(own)))
                return cursor + len(closing)
            own.append(text[cursor])
            cursor += 1
        self.literals.append((*self.position(quote), "".join(own)))
        return length

    def scan_interpolation(self, index: int) -> int:
        """`index` points just past `\\(`; returns the index just past its `)`."""
        text, length = self.text, len(self.text)
        depth = 1
        while index < length:
            character = text[index]
            if character == "(":
                depth += 1
                index += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    return index + 1
                index += 1
            elif character == "#" or character == '"':
                hashes = 0
                cursor = index
                while cursor < length and text[cursor] == "#":
                    hashes += 1
                    cursor += 1
                if cursor < length and text[cursor] == '"':
                    index = self.scan_string(cursor, hashes)
                else:
                    index += 1
            elif text.startswith("//", index):
                newline = text.find("\n", index)
                index = length if newline < 0 else newline
            else:
                index += 1
        return index

    def skip_comment(self, index: int) -> int:
        text, length = self.text, len(self.text)
        if text.startswith("//", index):
            newline = text.find("\n", index)
            return length if newline < 0 else newline
        depth = 0
        while index < length:
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
                if depth == 0:
                    return index
            else:
                index += 1
        return length


def string_literals(text: str) -> list[tuple[int, int, str]]:
    """Every string literal as (line, column, own text), column in UTF-8 bytes.

    A real scanner rather than a regex: a regex cannot tell a literal from the same
    characters inside a comment, and it stops at the first nested quote — which is
    what made the hand-rolled audit of 2026-09-21 report half a string
    (`清理失败：\\(report.failed.joined(separator: "` ) as a candidate.
    """
    scanner = _Scanner(text)
    text_length = len(text)
    index = 0
    while index < text_length:
        character = text[index]
        if text.startswith("//", index) or text.startswith("/*", index):
            index = scanner.skip_comment(index)
            continue
        if character == "#" or character == '"':
            hashes = 0
            cursor = index
            while cursor < text_length and text[cursor] == "#":
                hashes += 1
                cursor += 1
            if cursor >= text_length or text[cursor] != '"':
                index += 1
                continue
            index = scanner.scan_string(cursor, hashes)
            continue
        index += 1
    return scanner.literals


def positions_still_land_on_quotes(path: pathlib.Path, keys: set[tuple[int, int]]) -> bool:
    """Whether every recorded literal position still points at a `"` in the source.

    An empty set is fine — the file was compiled and simply has nothing localizable.
    A file that no `.stringsdata` mentions is *not* fine (see `main`), which is why the
    caller passes `None` for that case instead of an empty set here.
    """
    if not keys:
        return True
    try:
        lines = path.read_bytes().split(b"\n")
    except OSError:
        return False
    for line, column in keys:
        if not 1 <= line <= len(lines):
            return False
        raw = lines[line - 1]
        if column - 1 >= len(raw) or raw[column - 1:column] != b'"':
            return False
    return True


def line_waiver(path: pathlib.Path, line: int) -> str | None:
    """The waiver reason for a literal starting on `line`, if any.

    A multi-line literal starts on the line of its opening triple quote, which cannot
    carry a trailing comment, so the line above counts too — that is where the
    AppleScript template's waiver sits.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for candidate in (line, line - 1):
        if 1 <= candidate <= len(lines):
            match = WAIVER.search(lines[candidate - 1])
            if match:
                return match.group(1).strip()
    return None


def main(argv: list[str]) -> int:
    script_directory = pathlib.Path(__file__).resolve().parent.parent
    derived_data = pathlib.Path(argv[1]) if len(argv) > 1 else script_directory / "build" / "DerivedData"

    positions = extracted_positions(derived_data)
    if not positions:
        print(
            f"错误：{derived_data} 下没有找到 .stringsdata，请先构建 app target（与 sync_string_catalog.sh 相同的前置条件）。",
            file=sys.stderr,
        )
        return 1

    sources = [
        path
        for directory in SOURCE_DIRECTORIES
        for path in sorted((script_directory / directory).rglob("*.swift"))
    ]

    # Stale extraction data is worse than none: `.stringsdata` records line *and*
    # column, so a shifted line turns every later literal in the file into a false
    # positive. Freshness is therefore checked by content, not by mtime — the build
    # system legitimately reuses a `.stringsdata` whose extracted strings did not
    # change, leaving an old mtime (the trap AGENTS.md records for
    # `sync_string_catalog.sh`). Every recorded position must still land on the
    # literal's opening quote.
    stale: list[tuple[pathlib.Path, str]] = []
    for path in sources:
        keys = positions.get(str(path.resolve()))
        if keys is None:
            stale.append((path, "没有任何 .stringsdata 提到它——这个文件没有被任何 target 编译"))
        elif not positions_still_land_on_quotes(path, keys):
            stale.append((path, "记录的提取位置已不再指向引号"))
    if stale:
        print("错误：以下源文件的提取位置已经对不上（多半是改了源码还没重新构建）：", file=sys.stderr)
        for path, reason in stale:
            print(f"  - {path.relative_to(script_directory)}：{reason}", file=sys.stderr)
        print(
            "行号/列号会因此错位，本脚本的判断不再可信；"
            "`xcodebuild -project XcodeSwitcher.xcodeproj -scheme \"Xcode Switcher\" "
            "-configuration Debug -derivedDataPath build/DerivedData build` 之后重试。",
            file=sys.stderr,
        )
        return 1

    chinese = 0
    localized = 0
    waived: list[tuple[pathlib.Path, int, str, str]] = []
    missing: list[tuple[pathlib.Path, int, str]] = []

    for path in sources:
        keys = positions.get(str(path.resolve()), set())
        for line, column, content in string_literals(path.read_text(encoding="utf-8")):
            if not CJK.search(content):
                continue
            chinese += 1
            if (line, column) in keys:
                localized += 1
                continue
            reason = line_waiver(path, line)
            if reason:
                waived.append((path, line, content, reason))
                continue
            missing.append((path, line, content))

    print(f"源文件里含中文的字符串字面量 {chinese} 个：编译器提取 {localized} 个，其余 {chinese - localized} 个")
    if waived:
        print(f"按 `unlocalized-audit:ok` 注释豁免 {len(waived)} 个：")
        for path, line, content, reason in waived:
            print(f"  - {path.relative_to(script_directory)}:{line}  {content!r} — {reason}")

    if missing:
        print(f"\n发现 {len(missing)} 处未本地化的中文，英文界面会原样显示：", file=sys.stderr)
        for path, line, content in missing:
            printable = content.replace("\n", "\\n")
            if len(printable) > 60:
                printable = printable[:57] + "…"
            print(f"  - {path.relative_to(script_directory)}:{line}  {printable!r}", file=sys.stderr)
        print(
            "\n请包进 String(localized:)，或在本行加 `unlocalized-audit:ok：<理由>` 说明为何不翻译。",
            file=sys.stderr,
        )
        return 1

    print("所有含中文的字面量要么已进入 String Catalog，要么有明确的豁免理由。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
