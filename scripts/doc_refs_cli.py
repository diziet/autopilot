"""The commands a repo defines and the flags they accept, for check_doc_refs.py.

Python sources are read with `ast`; nothing is imported or run. A flag is defined
when a string literal starting with `--` is a positional argument of an
`add_argument` (argparse), `option` (click) or `Option` (Typer) call. click's
`--x/--no-x` form defines both names. A subcommand is a function decorated with
`.command()` or `.group()` (name from the argument, else the function name with
`_` as `-`), a `.command(...)(func)` call, or an `add_parser`, `add_typer` or
`add_command` call with a name. A program's flags are those defined in its entry
file and every repo module it imports, directly or transitively. A shell script
defines a flag in a `case` pattern (`--dry-run)`) or a test (`[ "$1" = "--x" ]`).

TODO: Typer and click also derive a flag from a parameter name when the option
call names none (`verbose: bool = typer.Option(False)`). No repo in the 2026-09
rollout relies on that, so it is not read.

Local change in autopilot (2026-09-24), not in the llm-reliability-benchmark copy:
`all_flags` also reads tracked files that have no extension and start with a
bash, sh or zsh shebang, because autopilot's entry points in bin/ have no `.sh`.
"""

from __future__ import annotations

import ast
import re
import tomllib
from dataclasses import dataclass
from typing import TYPE_CHECKING

from doc_common import git_lines, is_excluded

if TYPE_CHECKING:
    from pathlib import Path

FLAG_CALLS = frozenset({"add_argument", "option", "Option"})
COMMAND_DECORATORS = frozenset({"command", "group"})
NAMED_SUBCOMMAND_CALLS = frozenset({"add_parser", "add_typer", "add_command"})
# argparse, click and Typer all add --help to every command.
BUILTIN_FLAGS = frozenset({"--help"})
FLAG_TEXT = re.compile(r"(?<![\w-])--[A-Za-z0-9][\w-]*")
SHELL_CASE_PATTERN = re.compile(r"^\s*\(?([\"']?--[^)\s]*)\)", re.MULTILINE)
SHELL_COMPARISON = re.compile(r"=\s*[\"']?(--[A-Za-z0-9][\w-]*)[\"']?\s*\]")
TEST_DIR_NAMES = frozenset({"tests", "test"})
SHELL_SHEBANG = re.compile(r"#!.*\b(?:bash|sh|zsh)\b")


@dataclass(frozen=True)
class Program:
    """A command the repo defines: its label in findings, flags and subcommands."""

    label: str
    flags: frozenset[str]
    subcommands: frozenset[str]


def _call_name(node: ast.expr) -> str:
    """Return the called attribute or function name, or '' for other callees."""
    if isinstance(node, ast.Attribute):
        return node.attr
    return node.id if isinstance(node, ast.Name) else ""


def _strings(nodes: list[ast.expr]) -> list[str]:
    """Return the string literals among call arguments."""
    return [
        n.value
        for n in nodes
        if isinstance(n, ast.Constant) and isinstance(n.value, str)
    ]


def _command_name(call: ast.Call, fallback: str) -> str:
    """Return a command's explicit name argument, or the fallback name dashed."""
    for keyword in call.keywords:
        if keyword.arg == "name" and isinstance(keyword.value, ast.Constant):
            return str(keyword.value.value)
    named = _strings(call.args)
    return named[0] if named else fallback.replace("_", "-")


def definitions(tree: ast.Module) -> tuple[set[str], set[str]]:
    """Return the (flags, subcommands) one parsed module defines."""
    flags: set[str] = set()
    subcommands: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            for decorator in node.decorator_list:
                if isinstance(decorator, ast.Call) and (
                    _call_name(decorator.func) in COMMAND_DECORATORS
                ):
                    subcommands.add(_command_name(decorator, node.name))
        if not isinstance(node, ast.Call):
            continue
        name = _call_name(node.func)
        if name in FLAG_CALLS:
            for literal in _strings(node.args):
                flags.update(
                    p.strip() for p in literal.split("/") if p.strip().startswith("--")
                )
        elif name in NAMED_SUBCOMMAND_CALLS:
            named = _command_name(node, "")
            if named:
                subcommands.add(named)
        elif (
            isinstance(node.func, ast.Call) and _call_name(node.func.func) == "command"
        ):
            target = node.args[0] if node.args else None
            fallback = target.id if isinstance(target, ast.Name) else ""
            subcommands.add(_command_name(node.func, fallback))
    return flags, subcommands - {""}


def shell_flags(text: str) -> frozenset[str]:
    """Return the flags a shell script tests for in `case` patterns or `[ ... ]`."""
    flags = set(SHELL_COMPARISON.findall(text))
    for pattern in SHELL_CASE_PATTERN.findall(text):
        flags.update(FLAG_TEXT.findall(pattern))
    return frozenset(flags)


def is_extensionless_shell_script(root: Path, relative: str) -> bool:
    """True for a file with no extension whose first line is a shell shebang."""
    if "." in relative.rsplit("/", 1)[-1]:
        return False
    try:
        with (root / relative).open("rb") as handle:
            first_line = handle.readline(200).decode("utf-8", "replace")
    except OSError:
        return False
    return SHELL_SHEBANG.match(first_line) is not None


def is_test_path(relative: str) -> bool:
    """True for test modules and anything under a tests/ or test/ directory."""
    parts = relative.split("/")
    name = parts[-1]
    return (
        any(part in TEST_DIR_NAMES for part in parts[:-1])
        or name.startswith("test_")
        or name.endswith("_test.py")
        or name == "conftest.py"
    )


class ProgramIndex:
    """Lazily parses a repo's Python files and answers which program defines what."""

    def __init__(self, root: Path) -> None:
        """Read console scripts from pyproject.toml; parse modules on demand."""
        self.root = root
        self._trees: dict[Path, ast.Module | None] = {}
        self._programs: dict[tuple[str, Path], Program] = {}
        self._all_flags: frozenset[str] | None = None
        self.console_scripts: dict[str, str] = {}
        pyproject = root / "pyproject.toml"
        if pyproject.is_file():
            data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
            scripts = data.get("project", {}).get("scripts", {})
            self.console_scripts = {str(k): str(v) for k, v in scripts.items()}

    def _tree(self, path: Path) -> ast.Module | None:
        """Parse a file once; None when it is not valid Python."""
        if path not in self._trees:
            try:
                self._trees[path] = ast.parse(path.read_text(encoding="utf-8"))
            except (SyntaxError, UnicodeDecodeError, OSError):
                self._trees[path] = None
        return self._trees[path]

    def module_file(
        self, dotted: str, importer: Path | None = None, level: int = 0
    ) -> Path | None:
        """Resolve an import to a repo file (root, src/ or the importer's directory)."""
        parts = dotted.split(".") if dotted else []
        if level:
            if importer is None or level > len(importer.parents):
                return None
            bases = [importer.parents[level - 1]]
        else:
            bases = [self.root, self.root / "src"]
            if importer is not None:
                bases.append(importer.parent)
        for base in bases:
            stem = base.joinpath(*parts)
            for candidate in (stem.with_suffix(".py"), stem / "__init__.py"):
                if parts and candidate.is_file() and self.root in candidate.parents:
                    return candidate
            if not parts and (base / "__init__.py").is_file():
                return base / "__init__.py"
        return None

    def _imports(self, path: Path, tree: ast.Module) -> list[Path]:
        """Return the repo files one module imports, including `from pkg import mod`."""
        found: list[Path | None] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                found.extend(self.module_file(alias.name, path) for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                base = node.module or ""
                found.append(self.module_file(base, path, node.level))
                for alias in node.names:
                    submodule = f"{base}.{alias.name}" if base else alias.name
                    found.append(self.module_file(submodule, path, node.level))
        return [p for p in found if p is not None]

    def _python_program(self, label: str, entry: Path) -> Program:
        """Union the definitions of an entry file and every repo module it imports."""
        flags, subcommands = set(BUILTIN_FLAGS), set()
        queue, seen = [entry], {entry}
        while queue:
            path = queue.pop()
            tree = self._tree(path)
            if tree is None:
                continue
            file_flags, file_subcommands = definitions(tree)
            flags |= file_flags
            subcommands |= file_subcommands
            for imported in self._imports(path, tree):
                if imported not in seen:
                    seen.add(imported)
                    queue.append(imported)
        return Program(label, frozenset(flags), frozenset(subcommands))

    def _program(self, label: str, entry: Path) -> Program:
        """Build a Python program once per label and entry file."""
        key = (label, entry)
        if key not in self._programs:
            self._programs[key] = self._python_program(label, entry)
        return self._programs[key]

    def console(self, name: str) -> Program | None:
        """Return the program behind a pyproject console script, or None."""
        target = self.console_scripts.get(name)
        entry = self.module_file(target.split(":")[0]) if target else None
        return self._program(name, entry) if entry else None

    def module(self, dotted: str) -> Program | None:
        """Return the program `python -m <dotted>` runs, or None outside the repo."""
        entry = self.module_file(f"{dotted}.__main__") or self.module_file(dotted)
        return self._program(f"python -m {dotted}", entry) if entry else None

    def script(self, relative: str) -> Program:
        """Return the program for a repo script: Python by AST, others by text."""
        path = self.root / relative
        if path.suffix == ".py":
            return self._program(relative, path)
        text = path.read_text(encoding="utf-8", errors="replace")
        return Program(relative, shell_flags(text), frozenset())

    def subcommand_owner(self, word: str) -> Program | None:
        """Return the only console script with 2+ subcommands that has `word` as one."""
        owners = [
            program
            for name in sorted(self.console_scripts)
            if (program := self.console(name)) is not None
            and len(program.subcommands) >= 2
            and word in program.subcommands
        ]
        return owners[0] if len(owners) == 1 else None

    def all_flags(self) -> frozenset[str]:
        """Every flag a non-test Python file or shell script in the repo defines."""
        if self._all_flags is None:
            flags = set(BUILTIN_FLAGS)
            listed = git_lines(self.root, "ls-files", "--", "*.py", "*.sh", "*.bash")
            listed += [
                rel
                for rel in git_lines(self.root, "ls-files")
                if is_extensionless_shell_script(self.root, rel)
            ]
            for rel in listed:
                path = self.root / rel
                if is_excluded(rel) or is_test_path(rel) or not path.is_file():
                    continue
                if rel.endswith(".py"):
                    tree = self._tree(path)
                    flags |= definitions(tree)[0] if tree is not None else set()
                else:
                    flags |= self.script(rel).flags
            self._all_flags = frozenset(flags)
        return self._all_flags
