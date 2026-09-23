"""Blocking gate: repo references in tracked .md code spans must resolve.

Reads every inline code span in each tracked .md file outside fixtures, generated
and data trees. Fenced blocks, HTML comments and ~~struck-through~~ text are not
read. In each span:

- one path-shaped token (it contains `/` or ends in a known extension) must name
  a file or directory in the tree, or a path git ignores;
- `make <target>` must name a Makefile target;
- `--flag` must be defined by the command the span names: a pyproject console
  script, a repo script path, `python -m <module>`, or a subcommand of a console
  script. A console script with 2+ subcommands must define the subcommand too.
  A span of flags alone is checked against every flag the repo defines.

Exemptions live in docs/doc-refs-allow.txt, one per line:
`<doc glob> | <reference glob> | <reason>`. The reference is the text a finding
prints between backticks. An exemption that matches no finding fails the check.
Exit 0 when clean, 1 on findings or stale exemptions, 2 on a usage or
allowlist error.

TODO: read `make` lines in fenced shell blocks, `VAR=path` values in `make` spans,
flags passed through `args="..."`, and relative Markdown link targets.
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

from doc_common import code_spans, list_docs, makefile_rules
from doc_refs_cli import Program, ProgramIndex
from doc_refs_tree import (
    TreeIndex,
    ignore_probes,
    ignored_paths,
    path_candidate,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = "docs/doc-refs-allow.txt"
MAKE_COMMANDS = frozenset({"make", "gmake"})
# These select another Makefile. TODO: resolve them instead of skipping the span.
OTHER_MAKEFILE = frozenset({"-C", "-f", "--directory", "--file", "--makefile"})
MAKE_OPTIONS_WITH_VALUE = frozenset({"-I", "-o", "-W"})
PYTHONS = frozenset({"python", "python3", ".venv/bin/python", "$(PY)"})
SHELLS = frozenset({"bash", "sh", "zsh"})
SEPARATORS = frozenset({"&&", "||", ";", "|"})
FLAG = re.compile(r"--[A-Za-z0-9][\w-]*")
WORD = re.compile(r"[a-z][a-z0-9_-]*")
TARGET = re.compile(r"[\w./-]+")
ENV_ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=")


class AllowlistError(ValueError):
    """The allowlist file has a malformed line."""


@dataclass(frozen=True)
class Finding:
    """One reference in a doc that does not resolve."""

    doc: str
    line: int
    kind: str
    reference: str
    detail: str
    ignore_probes: tuple[str, ...] = ()

    def render(self) -> str:
        """Return the failure line: file, line, kind, reference and reason."""
        return f"{self.doc}:{self.line}: {self.kind} `{self.reference}` {self.detail}"


@dataclass(frozen=True)
class Exemption:
    """One allowlist entry and the line it came from."""

    line: int
    doc_glob: str
    reference_glob: str
    reason: str

    def matches(self, finding: Finding) -> bool:
        """True when the entry's globs match the finding's doc and reference."""
        return fnmatch.fnmatchcase(finding.doc, self.doc_glob) and fnmatch.fnmatchcase(
            finding.reference, self.reference_glob
        )


def load_exemptions(path: Path, label: str = ALLOWLIST) -> list[Exemption]:
    """Parse the allowlist; a missing file means no exemptions."""
    if not path.is_file():
        return []
    entries: list[Exemption] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in raw.split("|", 2)]
        if len(fields) != 3 or not all(fields):
            raise AllowlistError(
                f"{label}:{number}: expected `<doc glob> | <reference glob> | "
                f"<reason>` with all three fields filled, got: {raw.strip()}"
            )
        entries.append(Exemption(number, *fields))
    return entries


class Checker:
    """Resolves the references in one repo's docs against its tree and commands."""

    def __init__(self, root: Path) -> None:
        """Index the tree, the Makefile targets and the Python commands once."""
        self.root = root
        self.tree = TreeIndex.build(root)
        self.targets = frozenset(makefile_rules(root))
        self.programs = ProgramIndex(root)
        self.checked: list[str] = []

    def check_doc(self, doc: str) -> list[Finding]:
        """Return the unresolved references in one doc, ignored paths included."""
        text = (self.root / doc).read_text(encoding="utf-8")
        findings: list[Finding] = []
        for span in code_spans(text):
            if span.is_struck:
                continue
            words = _split(span.text)
            if len(words) == 1 and not words[0].startswith("-"):
                findings += self._check_path(doc, span.line, words[0])
                continue
            for command in _commands(words):
                findings += self._check_command(doc, span.line, command)
        return findings

    def _check_path(self, doc: str, line: int, token: str) -> list[Finding]:
        """Report a path-shaped token that names nothing in the tree."""
        candidate = path_candidate(token)
        if candidate is None:
            return []
        self.checked.append(token)
        if self.tree.locate(candidate, doc) is not None:
            return []
        probes = tuple(ignore_probes(candidate, doc))
        detail = "does not exist in the tree"
        return [Finding(doc, line, "path", token, detail, probes)]

    def _check_command(self, doc: str, line: int, words: list[str]) -> list[Finding]:
        """Check one command: make targets, or a repo program's subcommand and flags."""
        head = words[0]
        if head in MAKE_COMMANDS:
            return self._check_make(doc, line, words[1:])
        if head.startswith("--"):
            return self._check_flags(doc, line, None, words)
        findings, program, rest = self._program(doc, line, words)
        if program is None:
            return findings
        if len(program.subcommands) >= 2 and rest and WORD.fullmatch(rest[0]):
            reference = f"{program.label} {rest[0]}"
            self.checked.append(reference)
            if rest[0] not in program.subcommands:
                detail = f"is not a subcommand of {program.label}"
                findings.append(Finding(doc, line, "subcommand", reference, detail))
        return findings + self._check_flags(doc, line, program, rest)

    def _program(
        self, doc: str, line: int, words: list[str]
    ) -> tuple[list[Finding], Program | None, list[str]]:
        """Identify the repo program a command runs; None for an outside command."""
        if words[0] == "uv":
            words = words[2:] if words[1:2] == ["run"] else []
        if words and words[0] in PYTHONS:
            if words[1:2] == ["-m"] and len(words) > 2:
                return [], self.programs.module(words[2]), words[3:]
            words = words[1:]
        elif words and words[0] in SHELLS:
            words = words[1:]
        if not words:
            return [], None, []
        head = words[0]
        if "/" in head or head.endswith((".py", ".sh")):
            candidate = path_candidate(head)
            located = self.tree.locate(candidate, doc) if candidate else None
            if located is None:
                return self._check_path(doc, line, head), None, []
            self.checked.append(head)
            if not (self.root / located).is_file():
                return [], None, []
            return [], self.programs.script(located), words[1:]
        program = self.programs.console(head)
        if program is not None:
            return [], program, words[1:]
        return [], self.programs.subcommand_owner(head), words

    def _check_make(self, doc: str, line: int, args: list[str]) -> list[Finding]:
        """Report `make` targets the Makefile does not define."""
        findings: list[Finding] = []
        if OTHER_MAKEFILE.intersection(args):
            return findings
        skip_value = False
        for arg in args:
            if skip_value:
                skip_value = False
                continue
            skip_value = arg in MAKE_OPTIONS_WITH_VALUE
            if arg.startswith("-") or "=" in arg or arg.isdigit():
                continue
            if not TARGET.fullmatch(arg):
                continue
            self.checked.append(f"make {arg}")
            if arg not in self.targets:
                detail = "is not a target in the Makefile"
                findings.append(
                    Finding(doc, line, "make-target", f"make {arg}", detail)
                )
        return findings

    def _check_flags(
        self, doc: str, line: int, program: Program | None, words: list[str]
    ) -> list[Finding]:
        """Report `--flags` the program, or for bare flags the whole repo, lacks."""
        defined = program.flags if program else self.programs.all_flags()
        owner = program.label if program else "any command in the repo"
        findings: list[Finding] = []
        for word in words:
            if word == "--":
                break
            flag = FLAG.match(word.lstrip("[("))
            if flag is None:
                continue
            self.checked.append(flag.group())
            if flag.group() not in defined:
                detail = f"is not defined by {owner}"
                findings.append(Finding(doc, line, "flag", flag.group(), detail))
        return findings


def _split(text: str) -> list[str]:
    """Split a span into shell words; fall back to whitespace on bad quoting."""
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def _commands(words: list[str]) -> list[list[str]]:
    """Split shell words at `&&`, `||`, `;` and `|`; drop leading VAR=value words."""
    commands: list[list[str]] = [[]]
    for word in words:
        if word in SEPARATORS:
            commands.append([])
        elif commands[-1] or not ENV_ASSIGNMENT.match(word):
            commands[-1].append(word)
    return [command for command in commands if command]


def drop_ignored(root: Path, findings: list[Finding]) -> list[Finding]:
    """Remove path findings git ignores; they are runtime or build artifacts."""
    probes = sorted({probe for f in findings for probe in f.ignore_probes})
    ignored = ignored_paths(root, probes)
    return [f for f in findings if not ignored.intersection(f.ignore_probes)]


def run(root: Path, allowlist: Path) -> int:
    """Check every doc, apply exemptions, print the verdict; return the exit code."""
    exemptions = load_exemptions(allowlist)
    docs = list_docs(root)
    checker = Checker(root)
    findings = drop_ignored(root, [f for doc in docs for f in checker.check_doc(doc)])
    problems = [
        f.render() for f in findings if not any(e.matches(f) for e in exemptions)
    ]
    problems += [
        f"{ALLOWLIST}:{e.line}: stale exemption `{e.doc_glob} | "
        f"{e.reference_glob}` matches no finding; remove it"
        for e in exemptions
        if not any(e.matches(f) for f in findings)
    ]
    if not docs or not checker.checked:
        problems.append(
            f"read {len(docs)} docs and {len(checker.checked)} references; the doc "
            "listing or the span scanner is broken"
        )
    for problem in problems:
        print(f"check_doc_refs: FAIL {problem}", file=sys.stderr)
    if problems:
        print(
            f"check_doc_refs: {len(problems)} problem(s). Fix the doc, or exempt "
            f"the reference in {ALLOWLIST} with a reason.",
            file=sys.stderr,
        )
        return 1
    exempted = len(findings)
    print(
        f"check_doc_refs: ok ({len(docs)} docs, {len(checker.checked)} references, "
        f"{exempted} exempted)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI: exit 0 clean, 1 on findings, 2 on a usage or allowlist error."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    root: Path = options.root.resolve()
    if not (root / ".git").exists():
        print(f"check_doc_refs: {root} is not a git checkout", file=sys.stderr)
        return 2
    try:
        return run(root, root / ALLOWLIST)
    except AllowlistError as error:
        print(f"check_doc_refs: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
