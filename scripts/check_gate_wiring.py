"""Checks that check themselves: assert the repo's gates are all wired.

(a) every file under tests/ that defines a bats `@test` is a tests/*.bats file, where
    `bats tests/` finds it (bats does not recurse), and a named minimum set of bats files exists,
    so an empty glob cannot pass;
(b) every tests/tooling module that defines a test is collected by unittest discovery, and a
    named minimum set of modules is collected;
(c) every script under scripts/ is referenced from the Makefile, a hook, or another script, except
    the named operator scripts, and each named operator script still exists;
(d) the Makefile `gate` recipe runs scripts/gate.sh, and every Makefile target whose `## `
    comment says `Blocking gate` is in that script's full `stages="..."` list or is called by
    `make` from a listed stage's recipe, directly or through further `make` calls (`check` calls
    `lint` and `test`). The list is parsed, not searched as text, because a target name inside a
    message string is not a stage. scripts/merge.py runs only scripts/gate.sh, so gate.sh is the
    single list of gate stages.
The verdict is the exit code, never parsed output.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLING_TESTS = "tests/tooling"
BATS_TEST_PATTERN = re.compile(r"^@test ", re.MULTILINE)
PY_TEST_PATTERN = re.compile(r"^\s*def\s+test_", re.MULTILINE)
BLOCKING_TARGET_PATTERN = re.compile(r"^([A-Za-z0-9_-]+):.*## Blocking gate", re.MULTILINE)
RULE_PATTERN = re.compile(r"^([A-Za-z0-9_-]+):(?!=)")
MAKE_CALL_PATTERN = re.compile(r"(?:\$\(MAKE\)|\bmake\b)([^;&|\n]*)")
# Only the unindented full list matches, not the indented docs-only subset.
STAGES_PATTERN = re.compile(r'^stages="([^"]*)"', re.MULTILINE)
GATE_SCRIPT = "scripts/gate.sh"
KNOWN_BATS_FILES: frozenset[str] = frozenset(
    {
        "tests/test_codex_reviewer.bats",
        "tests/test_config.bats",
        "tests/test_dispatcher_cycle.bats",
        "tests/test_install.bats",
        "tests/test_smoke.bats",
        "tests/test_state.bats",
    }
)
KNOWN_TOOLING_MODULES: frozenset[str] = frozenset(
    {
        "test_check_doc_refs",
        "test_doc_checks_repo",
        "test_doc_common",
        "test_doc_facts",
        "test_gate_lock",
        "test_hooks",
        "test_merge",
    }
)
# Scripts a person runs by hand; no target, hook or script calls them.
OPERATOR_SCRIPTS: frozenset[str] = frozenset({"remove-crontab-entries.sh"})
# Targets that are the roots of the wiring and therefore need no caller.
WIRING_ROOTS = frozenset({"gate"})
# Prints one "<module> <test id>" line per collected test; exits 1 on an import error.
LIST_TOOLING_TESTS = """
import sys, unittest
def walk(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from walk(item)
        else:
            yield item
loader = unittest.TestLoader()
suite = loader.discover(sys.argv[1], pattern="test_*.py", top_level_dir=sys.argv[1])
if loader.errors:
    print("\\n".join(loader.errors), file=sys.stderr)
    sys.exit(1)
for test in walk(suite):
    print(type(test).__module__, test.id())
"""


def check_bats_files(root: Path, known: frozenset[str] = KNOWN_BATS_FILES) -> list[str]:
    """(a) Every file with a bats @test is a tests/*.bats file; the known set exists."""
    problems: list[str] = []
    for path in sorted((root / "tests").rglob("*")):
        if not path.is_file() or "__pycache__" in path.parts:
            continue
        relative = path.relative_to(root).as_posix()
        is_runnable = path.parent == root / "tests" and path.suffix == ".bats"
        if is_runnable:
            continue
        if BATS_TEST_PATTERN.search(path.read_text(errors="replace")):
            problems.append(f"bats tests that `bats tests/` does not run: {relative}")
    problems += [
        f"known bats file missing: {name}"
        for name in sorted(known)
        if not (root / name).is_file()
    ]
    return problems


def collected_tooling_modules(root: Path, python: str) -> set[str]:
    """Return the tests/tooling modules unittest collects; raise RuntimeError on import errors."""
    tests_dir = root / TOOLING_TESTS
    if not tests_dir.is_dir():
        return set()
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(root / "scripts"), str(tests_dir)])
    result = subprocess.run(
        [python, "-c", LIST_TOOLING_TESTS, str(tests_dir)],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"unittest collection failed:\n{result.stderr[-2000:]}")
    return {line.split(" ", 1)[0] for line in result.stdout.splitlines() if line}


def _tooling_test_files(root: Path) -> dict[str, Path]:
    """Map module name to path for each tests/tooling *.py file that defines a test method."""
    found: dict[str, Path] = {}
    tests_dir = root / TOOLING_TESTS
    if not tests_dir.is_dir():
        return found
    for path in sorted(tests_dir.rglob("*.py")):
        if "__pycache__" in path.parts:
            continue
        if PY_TEST_PATTERN.search(path.read_text(errors="replace")):
            found[path.stem] = path
    return found


def _is_imported_by(module: str, collected: set[str], files: dict[str, Path]) -> bool:
    """True when a collected module imports `module` (a shared base class of test cases)."""
    pattern = re.compile(rf"^\s*(from|import)\s+{re.escape(module)}\b", re.MULTILINE)
    return any(
        pattern.search(files[name].read_text(errors="replace"))
        for name in collected
        if name in files
    )


def check_tooling_tests(
    root: Path, python: str, known: frozenset[str] = KNOWN_TOOLING_MODULES
) -> list[str]:
    """(b) Every tooling module with tests is collected; the known set is collected."""
    try:
        collected = collected_tooling_modules(root, python)
    except RuntimeError as error:
        return [str(error)]
    files = _tooling_test_files(root)
    problems = [
        "tooling test module not collected by unittest (nor imported by a collected one): "
        f"{files[name].relative_to(root).as_posix()}"
        for name in sorted(set(files) - collected)
        if not _is_imported_by(name, collected, files)
    ]
    problems += [
        f"known tooling test module missing from collection: {name}"
        for name in sorted(known - collected)
    ]
    return problems


def _strip_comments(path: Path) -> str:
    """Return the file's text without lines that start with #."""
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


def check_scripts_referenced(
    root: Path, operator_scripts: frozenset[str] = OPERATOR_SCRIPTS
) -> list[str]:
    """(c) Every scripts/* file is named by the Makefile, a hook, or another script."""
    files = [
        root / "Makefile",
        *sorted((root / ".githooks").glob("*")),
        *sorted((root / "scripts").glob("*")),
    ]
    corpus = {path: _strip_comments(path) for path in files if path.is_file()}
    problems: list[str] = []
    for script in sorted((root / "scripts").glob("*")):
        if not script.is_file() or script.name in operator_scripts:
            continue
        import_pattern = re.compile(rf"\b(from|import)\s+{re.escape(script.stem)}\b")
        referenced = any(
            script.name in text or bool(import_pattern.search(text))
            for path, text in corpus.items()
            if path != script
        )
        if not referenced:
            problems.append(
                "orphan script (not referenced by Makefile, hooks or scripts): "
                f"scripts/{script.name}"
            )
    problems += [
        f"stale operator-script exemption: scripts/{name} does not exist"
        for name in sorted(operator_scripts)
        if not (root / "scripts" / name).is_file()
    ]
    return problems


def blocking_targets(makefile_text: str) -> list[str]:
    """Return Makefile targets whose help comment says `Blocking gate`."""
    return BLOCKING_TARGET_PATTERN.findall(makefile_text)


def recipes(makefile_text: str) -> dict[str, str]:
    """Map each rule's target to its recipe (the tab-indented lines after the rule line)."""
    result: dict[str, str] = {}
    current: str | None = None
    for line in makefile_text.splitlines():
        match = RULE_PATTERN.match(line)
        if match:
            current = match.group(1)
            result.setdefault(current, "")
        elif current is not None and line.startswith("\t"):
            result[current] += line + "\n"
        elif line.strip() and not line.startswith("#"):
            current = None
    return result


def make_calls(recipe: str) -> set[str]:
    """Return the targets a recipe passes to `make` or `$(MAKE)`."""
    targets: set[str] = set()
    for match in MAKE_CALL_PATTERN.finditer(recipe):
        tokens = match.group(1).split()
        skip_next = False
        for token in tokens:
            if skip_next:
                skip_next = False
            elif token in ("-C", "-f"):
                skip_next = True
            elif not token.startswith(("-", "$", '"', "'")) and "=" not in token:
                targets.add(token)
    return targets


def gate_stages(gate_text: str) -> list[str] | None:
    """Return the full stage list from gate.sh, or None without an unindented `stages=` line."""
    match = STAGES_PATTERN.search(gate_text)
    return match.group(1).split() if match else None


def check_blocking_targets_wired(root: Path) -> list[str]:
    """(d) `gate` runs gate.sh; every Blocking-gate target is a stage or called from one."""
    makefile = root / "Makefile"
    if not makefile.is_file():
        return ["Makefile missing"]
    makefile_text = makefile.read_text()
    rule_recipes = recipes(makefile_text)
    if GATE_SCRIPT not in rule_recipes.get("gate", ""):
        return [f"Makefile `gate` recipe does not run {GATE_SCRIPT}"]
    gate = root / GATE_SCRIPT
    stages = gate_stages(gate.read_text()) if gate.is_file() else None
    if stages is None:
        return [f'{GATE_SCRIPT} has no stages="..." list']
    reached = {stage for stage in stages if stage in rule_recipes}
    pending = list(reached)
    while pending:
        for called in make_calls(rule_recipes.get(pending.pop(), "")):
            if called in rule_recipes and called not in reached:
                reached.add(called)
                pending.append(called)
    return [
        f"blocking target '{target}' is not a stage in {GATE_SCRIPT} "
        "or called by a stage's recipe"
        for target in blocking_targets(makefile_text)
        if target not in WIRING_ROOTS and target not in reached
    ]


def run_all(root: Path, python: str) -> list[str]:
    """Run every check and return the combined list of problems."""
    return [
        *check_bats_files(root, KNOWN_BATS_FILES),
        *check_tooling_tests(root, python, KNOWN_TOOLING_MODULES),
        *check_scripts_referenced(root, OPERATOR_SCRIPTS),
        *check_blocking_targets_wired(root),
    ]


def main(argv: list[str] | None = None) -> int:
    """CLI: exit 1 on any problem, 2 when not run from the repo root."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    root: Path = options.root.resolve()
    if not (root / "Makefile").is_file():
        print(f"check_gate_wiring: {root} is not the repo root", file=sys.stderr)
        return 2
    problems = run_all(root, sys.executable)
    for problem in problems:
        print(f"check_gate_wiring: FAIL {problem}", file=sys.stderr)
    if problems:
        return 1
    print("check_gate_wiring: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
