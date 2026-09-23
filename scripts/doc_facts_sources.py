"""The Fact type and the value readers that scripts/doc_facts_registry.py builds on.

Stdlib only; another repo copies this file unchanged. Each reader raises FactError
when its source no longer has the expected shape, so a moved or renamed authority
fails `make doc-facts-check` instead of producing a stale value.
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from doc_common import makefile_rules

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path


class FactError(ValueError):
    """A fact's source is missing or no longer has the shape its reader expects."""


@dataclass(frozen=True)
class Fact:
    """A registered fact: where its value comes from, and how to compute it."""

    describe: str
    compute: Callable[[Path], str | int]


def read_text(root: Path, relative: str) -> str:
    """Return a repo file's text; FactError when it is missing."""
    path = root / relative
    if not path.is_file():
        raise FactError(f"{relative} does not exist")
    return path.read_text(encoding="utf-8")


def regex_group(root: Path, relative: str, pattern: str) -> str:
    """Return group 1 of the first multiline match of `pattern` in a file."""
    match = re.search(pattern, read_text(root, relative), re.MULTILINE)
    if match is None:
        raise FactError(f"{relative} has no line matching {pattern!r}")
    return match.group(1)


def count_distinct(root: Path, relative: str, pattern: str) -> int:
    """Return how many distinct group-1 values `pattern` matches in a file."""
    found = set(re.findall(pattern, read_text(root, relative), re.MULTILINE))
    if not found:
        raise FactError(f"{relative} has no line matching {pattern!r}")
    return len(found)


def makefile_recipe(root: Path, target: str) -> list[str]:
    """Return a Makefile target's recipe lines; FactError when the target is gone."""
    rules = makefile_rules(root)
    if target not in rules:
        raise FactError(f"the Makefile has no `{target}` target")
    return rules[target]


def pyproject_value(root: Path, dotted_key: str) -> Any:
    """Return a value from pyproject.toml by dotted key, e.g. `project.name`."""
    value: Any = tomllib.loads(read_text(root, "pyproject.toml"))
    for key in dotted_key.split("."):
        if not isinstance(value, dict) or key not in value:
            raise FactError(f"pyproject.toml has no `{dotted_key}`")
        value = value[key]
    return value
