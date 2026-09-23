"""Shared by the doc checks: tracked-doc listing, Markdown code spans, Makefile rules.

Stdlib only, so another repo can copy it unchanged. The Markdown scanner covers the
parts of CommonMark and GFM the checks depend on: fenced code blocks, inline code
spans, HTML comments and `~~` strikethrough. It is not a full Markdown parser.
"""

from __future__ import annotations

import bisect
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

# A directory component with one of these names marks fixtures, generated output or
# data. Their .md files are not authored prose, so neither check reads them.
EXCLUDED_DIR_NAMES = frozenset(
    {"fixtures", "generated", "data", "testdata", "node_modules", "vendor"}
)
FENCE_OPEN = re.compile(r"^[ \t]*(`{3,}|~{3,})")
BACKTICK_RUN = re.compile(r"`+")
BLANK_LINES = re.compile(r"\n[ \t]*\n")
COMMENT_OPEN = "<!--"
COMMENT_CLOSE = "-->"
STRIKE = "~~"
RULE_LINE = re.compile(r"^([^\s#:=][^#:=]*?)\s*::?(?!=)")
INCLUDE_LINE = re.compile(r"^-?s?include\s+(.+)$")
# Conditional lines inside a recipe do not end it (GNU make reads through them).
TRANSPARENT_LINE = re.compile(
    r"^\s*(?:$|#|ifeq\b|ifneq\b|ifdef\b|ifndef\b|else\b|endif\b)"
)


@dataclass(frozen=True)
class CodeSpan:
    """One inline code span: its 1-based line, its text, and whether it is struck."""

    line: int
    text: str
    is_struck: bool


def is_excluded(relative: str) -> bool:
    """True when a repo-relative path lies in a fixtures, generated or data tree."""
    return any(part in EXCLUDED_DIR_NAMES for part in relative.split("/")[:-1])


def git_lines(root: Path, command: str, *args: str) -> list[str]:
    """Run `git <command> -z <args>` in `root`; return the non-empty entries."""
    output = subprocess.run(
        ["git", command, "-z", *args],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [entry for entry in output.split("\0") if entry]


def keep_doc(root: Path, relative: str) -> bool:
    """True for a regular .md file outside excluded trees; symlinks are skipped."""
    path = root / relative
    return not is_excluded(relative) and not path.is_symlink() and path.is_file()


def list_docs(root: Path) -> list[str]:
    """Return tracked .md paths outside excluded trees, sorted."""
    return sorted(
        rel for rel in git_lines(root, "ls-files", "--", "*.md") if keep_doc(root, rel)
    )


def _fenced_ranges(text: str) -> list[tuple[int, int]]:
    """Return [start, end) offsets of fenced code blocks, fence lines included."""
    ranges: list[tuple[int, int]] = []
    offset = 0
    fence = ""
    start = 0
    for line in text.splitlines(keepends=True):
        match = FENCE_OPEN.match(line)
        if not fence and match:
            fence, start = match.group(1), offset
        elif (
            fence
            and match
            and match.group(1)[0] == fence[0]
            and len(match.group(1)) >= len(fence)
            and not line[match.end() :].strip()
        ):
            ranges.append((start, offset + len(line)))
            fence = ""
        offset += len(line)
    if fence:
        ranges.append((start, len(text)))
    return ranges


def _mask(text: str, ranges: list[tuple[int, int]]) -> str:
    """Replace each range with spaces, keeping newlines so offsets and lines hold."""
    chars = list(text)
    for start, end in ranges:
        for index in range(start, end):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def _inline_spans(text: str) -> list[tuple[int, int, str]]:
    """Return (start, end, raw content) of inline code spans in fence-masked text."""
    spans: list[tuple[int, int, str]] = []
    block_start = 0
    for block_end in [m.start() for m in BLANK_LINES.finditer(text)] + [len(text)]:
        runs = list(BACKTICK_RUN.finditer(text, block_start, block_end))
        index = 0
        while index < len(runs):
            opener = runs[index]
            width = opener.end() - opener.start()
            closer = next(
                (
                    k
                    for k in range(index + 1, len(runs))
                    if len(runs[k].group()) == width
                ),
                None,
            )
            escaped = opener.start() > 0 and text[opener.start() - 1] == "\\"
            if closer is None or escaped:
                index += 1
                continue
            content = text[opener.end() : runs[closer].start()]
            spans.append((opener.start(), runs[closer].end(), content))
            index = closer + 1
        block_start = block_end
    return spans


def _merge(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Sort ranges and merge overlaps, so `_inside` can bisect them."""
    merged: list[tuple[int, int]] = []
    for start, end in sorted(ranges):
        if merged and start < merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def _inside(position: int, ranges: list[tuple[int, int]]) -> bool:
    """True when `position` falls inside one of the sorted, disjoint ranges."""
    index = bisect.bisect_right(ranges, (position, sys.maxsize)) - 1
    return index >= 0 and ranges[index][0] <= position < ranges[index][1]


def _comment_ranges(text: str, spans: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Return HTML comment ranges whose opener is outside every code span."""
    ranges: list[tuple[int, int]] = []
    position = text.find(COMMENT_OPEN)
    while position != -1:
        if _inside(position, spans):
            position = text.find(COMMENT_OPEN, position + 1)
            continue
        close = text.find(COMMENT_CLOSE, position + len(COMMENT_OPEN))
        end = len(text) if close == -1 else close + len(COMMENT_CLOSE)
        ranges.append((position, end))
        position = text.find(COMMENT_OPEN, end)
    return ranges


def _struck_ranges(text: str, skip: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Pair `~~` markers outside code and comments, per paragraph, into ranges."""
    ranges: list[tuple[int, int]] = []
    block_start = 0
    for block_end in [m.start() for m in BLANK_LINES.finditer(text)] + [len(text)]:
        marks = [
            m.start()
            for m in re.finditer(re.escape(STRIKE), text[block_start:block_end])
            if not _inside(block_start + m.start(), skip)
        ]
        for opener, closer in zip(marks[::2], marks[1::2], strict=False):
            ranges.append((block_start + opener, block_start + closer))
        block_start = block_end
    return ranges


def code_regions(text: str) -> list[tuple[int, int]]:
    """Return sorted [start, end) ranges of fenced blocks and inline code spans."""
    fenced = _fenced_ranges(text)
    inline = [(start, end) for start, end, _ in _inline_spans(_mask(text, fenced))]
    return _merge(fenced + inline)


def code_spans(text: str) -> list[CodeSpan]:
    """Return the inline code spans outside fences and comments, in document order."""
    masked = _mask(text, _fenced_ranges(text))
    raw = _inline_spans(masked)
    span_ranges = [(start, end) for start, end, _ in raw]
    comments = _comment_ranges(masked, span_ranges)
    struck = _struck_ranges(masked, _merge(span_ranges + comments))
    newlines = [m.start() for m in re.finditer("\n", text)]
    spans: list[CodeSpan] = []
    for start, _end, content in raw:
        if _inside(start, comments):
            continue
        folded = content.replace("\n", " ")
        if folded.startswith(" ") and folded.endswith(" ") and folded.strip():
            folded = folded[1:-1]
        line = bisect.bisect_right(newlines, start) + 1
        spans.append(CodeSpan(line, folded, _inside(start, struck)))
    return spans


def _makefile_lines(root: Path, name: str, seen: set[str]) -> list[str]:
    """Return a makefile's lines with continuations joined, includes inlined."""
    path = root / name
    if name in seen or not path.is_file():
        return []
    seen.add(name)
    joined = path.read_text(encoding="utf-8").replace("\\\n", " ")
    lines: list[str] = []
    for line in joined.splitlines():
        include = INCLUDE_LINE.match(line)
        if include and "$" not in include.group(1):
            for included in include.group(1).split():
                if included.startswith("/"):
                    continue
                for match in sorted(root.glob(included)):
                    rel = match.relative_to(root).as_posix()
                    lines.extend(_makefile_lines(root, rel, seen))
            continue
        lines.append(line)
    return lines


def makefile_rules(root: Path, name: str = "Makefile") -> dict[str, list[str]]:
    """Map each explicit Makefile target to its recipe lines (tab prefix removed).

    Special targets (leading `.`), pattern rules (`%`) and computed names (`$`) are
    skipped. Lines inside `define` blocks are ignored.
    """
    rules: dict[str, list[str]] = {}
    current: list[str] = []
    in_define = False
    for line in _makefile_lines(root, name, set()):
        if in_define or line.startswith("define "):
            in_define = not line.startswith("endef")
            continue
        if line.startswith("\t"):
            for target in current:
                rules[target].append(line[1:])
            continue
        rule = RULE_LINE.match(line)
        if rule is None:
            if not TRANSPARENT_LINE.match(line):
                current = []
            continue
        current = [
            target
            for target in rule.group(1).split()
            if not target.startswith(".") and "%" not in target and "$" not in target
        ]
        for target in current:
            rules.setdefault(target, [])
    return rules
