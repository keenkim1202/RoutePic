#!/usr/bin/env python3
"""Sweep for comments worth a second look.

It does not judge — it only narrows down where to look. Delete, compress, or keep is decided by a
person (or a model) through the three ways in SKILL.md.

Usage:
    python3 scan.py                                  # changed vs the base branch
    python3 scan.py --base HEAD                      # uncommitted changes only
    python3 scan.py <files...>                        # named files
    python3 scan.py --ext .ts,.tsx --skip /dist/     # per-project targets
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

BUDGET = 3
DEFAULT_SUFFIXES = ".swift,.kt,.java,.ts,.tsx,.js,.jsx,.go,.rs,.rb,.c,.h,.cc,.cpp,.cs,.py,.sh"
DEFAULT_SKIPS = "/Generated/,/GeneratedSources/,/Derived/,/.build/,/node_modules/,/dist/,/build/"

COMMENT = re.compile(r"^\s*(///|//|#)(?!\!)")
BLANK_DOC = re.compile(r"^\s*(///|#|\*)\s*$")
MARK = re.compile(r"^\s*//\s*MARK:")
# Block comments: /* */, /** */ (Javadoc, JSDoc). Only recognised when the line starts with the
# opener, so a `/*` inside a string literal does not swallow the rest of the file.
BLOCK_OPEN = re.compile(r"^\s*/\*")
BLOCK_CLOSE = re.compile(r"\*/")
# Citation and link lines come out of the budget. That is not bulk, it is a thread to a document.
CITATION = re.compile(r"https?://|POLICY-\d|\.md\b|docs/decisions")
# Code examples stay **in** the budget. Exempt them and the biggest blocks survive — see SKILL.md § 1.
# How many lines are the example is counted separately, as grounds for a person to keep it.
FENCE = re.compile(r"^\s*(///|//|#)\s*```")


def git(*args: str) -> list[str]:
    out = subprocess.run(["git", *args], capture_output=True, text=True, check=False).stdout
    return [line for line in out.splitlines() if line]


def default_base() -> str:
    """The branch this repo integrates into, or origin/main when origin/HEAD is not set."""
    head = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    return head[0] if head else "origin/main"


def changed_files(base: str) -> list[str]:
    spec = f"{base}...HEAD" if base != "HEAD" else "HEAD"
    # Three sources, because each misses what the others see: the commits on this branch, the
    # tracked edits not committed yet, and the files git is not tracking at all. A file just
    # edited is where the freshest comments are, and a commit range cannot see it.
    names = git("diff", "--name-only", spec)
    names += git("diff", "--name-only", "HEAD")
    names += git("ls-files", "--others", "--exclude-standard")
    return list(dict.fromkeys(names))


def is_target(path: str, suffixes: set[str], skips: tuple[str, ...]) -> bool:
    if Path(path).suffix not in suffixes:
        return False
    if any(part in f"/{path}" for part in skips):
        return False
    return Path(path).exists()


def comment_flags(lines: list[str]) -> list[bool]:
    """Mark each line as a comment line or not, tracking /* */ runs across lines."""
    flags, inside = [], False
    for text in lines:
        if inside:
            flags.append(True)
            if BLOCK_CLOSE.search(text):
                inside = False
            continue
        if BLOCK_OPEN.match(text):
            flags.append(True)
            inside = not BLOCK_CLOSE.search(text)
            continue
        flags.append(bool(COMMENT.match(text)))
    return flags


def blocks(lines: list[str], flags: list[bool]):
    """Group runs of comment lines into (start_line, lines)."""
    start, buf = 0, []
    for number, (text, is_comment) in enumerate(zip(lines, flags), start=1):
        if is_comment and not MARK.match(text):
            if not buf:
                start = number
            buf.append(text)
            continue
        if buf:
            yield start, buf
            buf = []
    if buf:
        yield start, buf


def fenced_count(buf: list[str]) -> int:
    """Lines inside code fences, fences included. An unclosed fence is not read as an example."""
    if sum(1 for text in buf if FENCE.match(text)) % 2:
        return 0
    count, inside = 0, False
    for text in buf:
        if FENCE.match(text):
            inside = not inside
            count += 1
            continue
        if inside:
            count += 1
    return count


def scan(path: str) -> tuple[int, list[str]]:
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    flags = comment_flags(lines)
    total = sum(flags)
    notes: list[str] = []

    for start, buf in blocks(lines, flags):
        budgeted = [text for text in buf if not CITATION.search(text)]
        if len(budgeted) > BUDGET:
            fenced = fenced_count(buf)
            example = f", {fenced} fenced" if fenced else ""
            notes.append(f"{path}:{start}  {len(buf)} lines (budget {len(budgeted)}{example}) over budget")
        blanks = [i for i, text in enumerate(buf) if BLANK_DOC.match(text)]
        if blanks and len(buf) <= BUDGET + 1:
            notes.append(f"{path}:{start + blanks[0]}  blank separator — the block is too short to split")

    return total, notes


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--base", default=None, help="compare against this ref (default: origin/HEAD)")
    parser.add_argument("--ext", default=DEFAULT_SUFFIXES, help="comma-separated target extensions")
    parser.add_argument("--skip", default=DEFAULT_SKIPS, help="comma-separated path fragments to skip")
    args = parser.parse_args()

    suffixes = {e if e.startswith(".") else f".{e}" for e in args.ext.split(",") if e}
    skips = tuple(s for s in args.skip.split(",") if s)
    base = args.base or default_base()

    paths = [p for p in (args.files or changed_files(base)) if is_target(p, suffixes, skips)]
    if not paths:
        print(f"nothing in scope — no changes in {', '.join(sorted(suffixes))}")
        return 0

    total, notes = 0, []
    print(f"{'file':<52} comments")
    for path in sorted(paths):
        count, file_notes = scan(path)
        total += count
        notes += file_notes
        print(f"  {Path(path).name:<50} {count:>4}")
    print(f"  {'total':<50} {total:>4}")

    print(f"\n{len(notes)} to look at")
    for note in notes:
        print(f"  {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
