"""Regenerate or check the fact values written into tracked .md files.

A fact lives in prose between markers, `<!-- fact:NAME -->VALUE<!-- /fact -->`,
and GitHub renders only VALUE. scripts/doc_facts_registry.py maps each NAME to a
function that computes VALUE from the tree. A marker inside a code span or fenced
block is an example and is left alone. A marker must not start a line, because
CommonMark reads a line that starts with `<!--` as raw HTML.

Modes:
  (none)       read-only check: print a diff and exit 1 when a value is stale
  --write      regenerate: rewrite stale values and print `doc_facts: rewrote
               <path>` once per rewritten file
  --fix-stale  gate: print the diff, rewrite, then exit 1 so the change is
               reviewed and staged

Every mode exits 1 without writing when a marker names an unregistered fact, a
registered fact has no marker, or a fact's source is missing. Exit 2 when the
root is not a git checkout.
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from doc_common import code_regions, keep_doc
from doc_facts_sources import Fact, FactError

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY = "scripts/doc_facts_registry.py"
PROBE = "<!-- fact:"
MARKER = re.compile(r"<!-- fact:([a-z0-9][a-z0-9-]*) -->(.*?)<!-- /fact -->")
LINE_START = re.compile(r"[ \t]*(?:[-*+>]|\d+[.)])?[ \t]*")
UNSAFE_VALUE = re.compile(r"\n|<!--|-->")


@dataclass(frozen=True)
class Marker:
    """One live marker: its doc, 1-based line, span in the text and fact name."""

    doc: str
    line: int
    start: int
    end: int
    name: str
    current: str


def marked_docs(root: Path) -> list[str]:
    """Return tracked .md files that contain a fact marker, via one `git grep`."""
    result = subprocess.run(
        ["git", "grep", "-l", "-z", "-F", PROBE, "--", "*.md"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise FactError(f"git grep failed: {result.stderr.strip()}")
    return sorted(d for d in result.stdout.split("\0") if d and keep_doc(root, d))


def find_markers(doc: str, text: str) -> tuple[list[Marker], list[str]]:
    """Return the live markers in a doc and any marker that starts a line."""
    regions = code_regions(text)
    markers: list[Marker] = []
    problems: list[str] = []
    for match in MARKER.finditer(text):
        if any(start <= match.start() < end for start, end in regions):
            continue
        line_start = text.rfind("\n", 0, match.start()) + 1
        line = text.count("\n", 0, match.start()) + 1
        if LINE_START.fullmatch(text[line_start : match.start()]):
            problems.append(
                f"{doc}:{line}: fact marker starts a line, so CommonMark renders "
                "the line as raw HTML; put a word before it"
            )
        markers.append(
            Marker(doc, line, match.start(), match.end(), match[1], match[2])
        )
    return markers, problems


def compute_values(
    root: Path, registry: dict[str, Fact], names: set[str]
) -> dict[str, str]:
    """Compute each named fact once; FactError names the fact that failed."""
    values: dict[str, str] = {}
    for name in sorted(names):
        try:
            value = str(registry[name].compute(root))
        except (FactError, OSError) as error:
            raise FactError(
                f"fact '{name}' ({registry[name].describe}): {error}"
            ) from error
        if UNSAFE_VALUE.search(value):
            raise FactError(
                f"fact '{name}' computed a multi-line or marker-breaking value"
            )
        values[name] = value
    return values


def render(text: str, markers: list[Marker], values: dict[str, str]) -> str:
    """Return the text with every live marker's value replaced."""
    pieces: list[str] = []
    position = 0
    for marker in markers:
        pieces.append(text[position : marker.start])
        pieces.append(f"<!-- fact:{marker.name} -->{values[marker.name]}<!-- /fact -->")
        position = marker.end
    pieces.append(text[position:])
    return "".join(pieces)


def registry_problems(registry: dict[str, Fact], markers: list[Marker]) -> list[str]:
    """Report markers naming unregistered facts and registered facts nobody uses."""
    used = {marker.name for marker in markers}
    known = ", ".join(sorted(registry))
    problems = [
        f"{m.doc}:{m.line}: unknown fact '{m.name}'; registered: {known}"
        for m in markers
        if m.name not in registry
    ]
    problems += [
        f"registered fact '{name}' has no marker in any tracked .md file; "
        f"remove it from {REGISTRY}"
        for name in sorted(set(registry) - used)
    ]
    return problems


def run(root: Path, registry: dict[str, Fact], mode: str) -> int:
    """Check or rewrite every marked doc; return the exit code."""
    texts = {doc: (root / doc).read_text(encoding="utf-8") for doc in marked_docs(root)}
    markers: dict[str, list[Marker]] = {}
    problems: list[str] = []
    for doc, text in texts.items():
        markers[doc], line_problems = find_markers(doc, text)
        problems += line_problems
    every_marker = [m for doc_markers in markers.values() for m in doc_markers]
    problems += registry_problems(registry, every_marker)
    values: dict[str, str] = {}
    if not problems:
        try:
            values = compute_values(root, registry, {m.name for m in every_marker})
        except FactError as error:
            problems.append(str(error))
    for problem in problems:
        print(f"doc_facts: FAIL {problem}", file=sys.stderr)
    return 1 if problems else _apply(root, texts, markers, values, mode)


def _apply(
    root: Path,
    texts: dict[str, str],
    markers: dict[str, list[Marker]],
    values: dict[str, str],
    mode: str,
) -> int:
    """Diff or write the rendered docs according to the mode."""
    stale = 0
    for doc, text in texts.items():
        rendered = render(text, markers[doc], values)
        if rendered == text:
            continue
        stale += 1
        if mode != "write":
            for marker in markers[doc]:
                if marker.current != values[marker.name]:
                    print(
                        f"doc_facts: FAIL {doc}:{marker.line}: fact '{marker.name}' "
                        f"states {marker.current!r}; the tree says "
                        f"{values[marker.name]!r}",
                        file=sys.stderr,
                    )
            diff = difflib.unified_diff(
                text.splitlines(keepends=True),
                rendered.splitlines(keepends=True),
                f"a/{doc}",
                f"b/{doc}",
            )
            sys.stderr.writelines(diff)
        if mode in ("write", "fix-stale"):
            (root / doc).write_text(rendered, encoding="utf-8")
            print(f"doc_facts: rewrote {doc}")
    count = sum(len(doc_markers) for doc_markers in markers.values())
    marked = sum(1 for doc_markers in markers.values() if doc_markers)
    if stale and mode != "write":
        action = (
            "rewrote them; review and stage"
            if mode == "fix-stale"
            else "run `make doc-facts`"
        )
        print(f"doc_facts: {stale} doc(s) stale; {action}", file=sys.stderr)
        return 1
    print(f"doc_facts: ok ({count} markers in {marked} docs)")
    return 0


def load_registry(root: Path) -> dict[str, Fact]:
    """Import FACTS from the registry file under `root`."""
    path = root / REGISTRY
    spec = importlib.util.spec_from_file_location("doc_facts_registry", path)
    if spec is None or spec.loader is None or not path.is_file():
        raise FactError(f"{REGISTRY} does not exist")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    facts = getattr(module, "FACTS", None)
    if not isinstance(facts, dict) or not all(
        isinstance(f, Fact) for f in facts.values()
    ):
        raise FactError(f"{REGISTRY} must define FACTS: dict[str, Fact]")
    return facts


def main(argv: list[str] | None = None) -> int:
    """CLI: check (default), --write, or --fix-stale."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--write", action="store_true", help="rewrite stale values")
    modes.add_argument("--fix-stale", action="store_true", help="rewrite, then fail")
    options = parser.parse_args(argv)
    root: Path = options.root.resolve()
    if not (root / ".git").exists():
        print(f"doc_facts: {root} is not a git checkout", file=sys.stderr)
        return 2
    mode = "write" if options.write else "fix-stale" if options.fix_stale else "check"
    try:
        return run(root, load_registry(root), mode)
    except FactError as error:
        print(f"doc_facts: FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
