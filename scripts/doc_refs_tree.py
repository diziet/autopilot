"""Path lookup for check_doc_refs.py: which tokens name repo paths, and do they exist.

A token is path-shaped when it contains `/` or is a file name with a known extension.
It resolves when it names a tracked or untracked-but-not-ignored file or directory:
relative to the repo root, relative to the doc's directory, or as the trailing
components of a deeper path (`core/db.py` matches `pkg/core/db.py`). `*`, `?`,
`<placeholder>` and `{placeholder}` match any characters. A missing path that git
ignores is a runtime or build artifact and is not reported.
"""

from __future__ import annotations

import fnmatch
import posixpath
import re
import subprocess
from dataclasses import dataclass
from typing import TYPE_CHECKING

from doc_common import git_lines

if TYPE_CHECKING:
    from pathlib import Path

KNOWN_EXTENSIONS = frozenset(
    {
        "bash", "cfg", "cjs", "conf", "css", "csv", "db", "go", "html", "ini",
        "ipynb", "j2", "jinja", "js", "json", "jsonl", "jsx", "lock", "md", "mjs",
        "plist", "png", "py", "pyi", "rs", "service", "sh", "sql", "svg", "toml",
        "ts", "tsv", "tsx", "txt", "xml", "yaml", "yml", "zsh",
    }
)  # fmt: skip
PATH_CHARS = re.compile(r"[\w.@*?/+-]+")
FILE_NAME = re.compile(r"[\w.@-]*\w[\w@-]*\.(\w+)")
PLACEHOLDER = re.compile(r"<[^<>]*>|\{[^{}]*\}")
LINE_SUFFIX = re.compile(r":\d+(?:[-,]\d+)*$")
GLOB_CHARS = re.compile(r"[*?]")
# Git refs and remote names are written like paths but are not files.
NOT_PATH_PREFIXES = ("origin/", "upstream/", "refs/")


def path_candidate(token: str) -> str | None:
    """Return the token as a repo-path pattern, or None when it is not path-shaped.

    `file.py:12` and `tests/x.py::test_y` name the file; placeholders become `*`.
    """
    token = LINE_SUFFIX.sub("", token.split("::", 1)[0])
    if any(mark in token for mark in ("...", "…", "://")):
        return None
    # `../x` is relative to a directory the doc does not name: the doc's own
    # directory in a link, the shell's working directory in a command.
    if token.startswith(("/", "~", "$", "-", "../", *NOT_PATH_PREFIXES)):
        return None
    token = PLACEHOLDER.sub("*", token).removeprefix("./")
    if not PATH_CHARS.fullmatch(token) or not re.search(r"[A-Za-z]", token):
        return None
    if "/" in token:
        return token
    name = FILE_NAME.fullmatch(token)
    return token if name and name.group(1) in KNOWN_EXTENSIONS else None


@dataclass(frozen=True)
class TreeIndex:
    """The repo's files and directories, and every component-aligned suffix of them."""

    entries: frozenset[str]
    suffixes: dict[str, str]

    @classmethod
    def build(cls, root: Path) -> TreeIndex:
        """Index tracked files plus untracked files git does not ignore."""
        listed = git_lines(
            root, "ls-files", "--cached", "--others", "--exclude-standard"
        )
        files = [rel for rel in listed if (root / rel).exists()]
        entries: set[str] = set()
        for rel in files:
            parts = rel.split("/")
            entries.update(
                "/".join(parts[:depth]) for depth in range(1, len(parts) + 1)
            )
        suffixes: dict[str, str] = {}
        for entry in sorted(entries):
            parts = entry.split("/")
            for start in range(1, len(parts)):
                suffixes.setdefault("/".join(parts[start:]), entry)
        return cls(frozenset(entries), suffixes)

    def locate(self, candidate: str, doc: str) -> str | None:
        """Return the entry a path candidate names, or None when nothing matches."""
        wanted = candidate.rstrip("/")
        options = [wanted]
        doc_dir = posixpath.dirname(doc)
        if doc_dir:
            options.append(posixpath.normpath(posixpath.join(doc_dir, wanted)))
        if GLOB_CHARS.search(wanted):
            for pattern in [*options, f"*/{wanted}"]:
                matched = fnmatch.filter(self.entries, pattern)
                if matched:
                    return sorted(matched)[0]
            return None
        for option in options:
            if option in self.entries:
                return option
        return self.suffixes.get(wanted)


def ignore_probes(candidate: str, doc: str) -> list[str]:
    """Return in-repo concrete paths to ask `git check-ignore` about.

    Each path is also asked with a trailing slash. A directory-only pattern such as
    `js/dist/` matches a missing `js/dist` only in that form, so without it the
    verdict would depend on whether a build created the directory.
    """
    concrete = GLOB_CHARS.sub("x", candidate)
    trailing = "/" if concrete.endswith("/") else ""
    probes = [concrete, posixpath.join(posixpath.dirname(doc), concrete)]
    normalized = {posixpath.normpath(probe) + trailing for probe in probes}
    normalized |= {path + "/" for path in normalized if not path.endswith("/")}
    return sorted(p for p in normalized if not p.startswith(("..", "/")))


def _ignore_query(root: Path, probe: str) -> str:
    """Return the probe, or the first symlink on its path, written without a slash.

    `git check-ignore` exits 128 for a path beyond a symbolic link, including the
    symlink itself written as `link/`, and that fails the whole batch. Git never
    tracks a path beyond a symlink, so such a path is ignored exactly when the
    symlink is, and the symlink is asked instead.
    """
    parts = probe.rstrip("/").split("/")
    for depth in range(1, len(parts) + 1):
        prefix = "/".join(parts[:depth])
        if (root / prefix).is_symlink():
            return prefix
    return probe


def ignored_paths(root: Path, paths: list[str]) -> set[str]:
    """Return the subset of `paths` that git ignores, in one `git check-ignore` call.

    A path beyond a symlink is asked about as the symlink (see `_ignore_query`).
    Exit 1 means nothing matched. Any other failure returns an empty set, so the
    check fails toward reporting a path rather than hiding it.
    """
    if not paths:
        return set()
    queries = {path: _ignore_query(root, path) for path in paths}
    result = subprocess.run(
        ["git", "check-ignore", "-z", "--stdin"],
        cwd=root,
        input="\0".join(sorted(set(queries.values()))) + "\0",
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        return set()
    ignored = {entry for entry in result.stdout.split("\0") if entry}
    return {path for path, query in queries.items() if query in ignored}
