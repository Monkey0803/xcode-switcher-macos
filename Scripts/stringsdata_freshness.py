#!/usr/bin/env python3
"""Decides whether a `.stringsdata` still lines up with the source it came from.

`sync_string_catalog.sh` used to answer this with mtimes, and that is wrong in the
case AGENTS.md records: a source whose *extracted strings* did not change gets its
`.stringsdata` reused from the build cache without being rewritten, so the file keeps
an old mtime while its content stays perfectly correct. Restoring a file with git
(`checkout`, `stash`) or `cp` bumps the source's mtime in the same direction. Either
way, every key that file contributes was marked `"extractionState": "stale"` and the
catalog gate went red with nothing actually wrong — twice on 2026-09-21 alone.

The judgment used instead is the one `audit_unlocalized_strings.py` already relies on:
a `.stringsdata` records each key's `startingLine` and `startingColumn`, and the column
points at the literal's **opening quote** — counted in UTF-8 bytes, not characters. A
file whose recorded positions all still land on a quote is one whose extraction still
lines up with the source; one whose positions no longer do had its source edited
without a rebuild, and merging it would resurrect or drop the wrong keys.

Usage:
    Scripts/stringsdata_freshness.py <file.stringsdata> [<file.stringsdata> …]

Fresh files are printed to stdout, one path per line, so the caller can collect them.
Files that are skipped are reported on stderr in the wording the shell script used.

Exit status:
    0  every file is current
    1  at least one file was skipped (the reasons are on stderr)
    2  no file was given
"""

from __future__ import annotations

import json
import pathlib
import sys

# Skip reasons, as shown to whoever runs the sync (kept in the shell script's voice).
STALE = "its recorded locations no longer line up with the source; rebuild the app target"
GONE = "its source no longer exists"
UNREADABLE = "its extraction metadata could not be read"


def load(path: pathlib.Path) -> tuple[pathlib.Path, set[tuple[int, int]]] | None:
    """The source a `.stringsdata` names and its recorded literal positions.

    Returns None when the metadata cannot be read at all. A file may legitimately
    have no positions (it was compiled but has nothing localizable).
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    source = data.get("source")
    if not source:
        return None
    positions: set[tuple[int, int]] = set()
    for entry in data.get("tables", {}).get("Localizable", []):
        location = entry.get("location") or {}
        line, column = location.get("startingLine"), location.get("startingColumn")
        if line and column:
            positions.add((line, column))
    return pathlib.Path(source).resolve(), positions


def positions_land_on_quotes(source: pathlib.Path, positions: set[tuple[int, int]]) -> bool:
    """Whether every recorded position still points at a `"` in the source.

    An empty set is fine: the file was compiled and simply has nothing localizable.
    """
    if not positions:
        return True
    try:
        lines = source.read_bytes().split(b"\n")
    except OSError:
        return False
    for line, column in positions:
        if not 1 <= line <= len(lines):
            return False
        raw = lines[line - 1]
        if column - 1 >= len(raw) or raw[column - 1:column] != b'"':
            return False
    return True


def freshness(path: pathlib.Path) -> str | None:
    """None when `path` is current, otherwise the reason to skip it."""
    loaded = load(path)
    if loaded is None:
        return UNREADABLE
    source, positions = loaded
    if not source.exists():
        return GONE
    return None if positions_land_on_quotes(source, positions) else STALE


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法：stringsdata_freshness.py <file.stringsdata> [<file.stringsdata> …]", file=sys.stderr)
        return 2
    skipped = 0
    for argument in argv[1:]:
        path = pathlib.Path(argument)
        reason = freshness(path)
        if reason is None:
            print(path)
            continue
        skipped += 1
        # Same shape as before the check became content-based, so a reader can still
        # grep for it: "skipping stale Views.stringsdata (…)".
        if reason is STALE:
            print(f"skipping stale {path.name} ({reason})", file=sys.stderr)
        else:
            print(f"skipping {path.name}: {reason}", file=sys.stderr)
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
