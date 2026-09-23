"""scripts/check_doc_refs.py: inject each broken reference, see it fail by name.

A unittest port of tests/tooling/test_check_doc_refs.py in llm-reliability-benchmark, where
the check comes from. The test names, fixture repo and assertions are the same.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from typing import TYPE_CHECKING

import check_doc_refs as refs
from doc_refs_tree import path_candidate
from gitfixture import TempDirTestCase, isolated_git_env

if TYPE_CHECKING:
    from pathlib import Path

FILES = {
    ".gitignore": "runs/\n",
    "Makefile": "lint: ## Blocking gate: lint\n\ttrue\ngate: lint\n\ttrue\n",
    "pyproject.toml": (
        '[project]\nname = "mini"\nversion = "0"\n'
        '[project.scripts]\nmini = "mini.cli:main"\n'
    ),
    "mini/__init__.py": "",
    "mini/options.py": 'import typer\nCONFIG = typer.Option(..., "--config")\n',
    "mini/cli.py": (
        "import typer\nfrom mini.options import CONFIG\napp = typer.Typer()\n\n"
        "@app.command()\ndef run(config: str = CONFIG) -> None: ...\n\n"
        '@app.command("score-all")\n'
        'def score(run_dir: str = typer.Option(..., "--run-dir")) -> None: ...\n'
    ),
    "scripts/tool.py": (
        "import argparse\nparser = argparse.ArgumentParser()\n"
        'parser.add_argument("--static-only", action="store_true")\n'
    ),
    "scripts/gate.sh": '[ "${1:-}" = "--docs-only" ] && echo docs\n',
    "docs/guide.md": "See `../README.md` and `guide.md`.\n",
}
CLEAN_README = (
    "Run `make gate`, `scripts/tool.py --static-only`, `bash scripts/gate.sh "
    "--docs-only`, `mini run --config x.yaml` and `score-all --run-dir DIR`.\n"
    "Files: `mini/cli.py`, `cli.py:3`, `options.py`, `runs/<id>/out.json`.\n"
    "Outside: `uv sync --locked`, `origin/main`, `/api/results`.\n"
)
PATH_SHAPES: list[tuple[str, str | None]] = [
    ("scripts/x.py", "scripts/x.py"),
    ("./tests/x.py::test_y", "tests/x.py"),
    ("core/db.py:59-61", "core/db.py"),
    ("runs/<run_id>/", "runs/*/"),
    ("uv.lock", "uv.lock"),
    ("summary.json", "summary.json"),
    ("origin/main", None),
    ("../feat/name", None),
    ("/api/results", None),
    ("https://example.com/a", None),
    ("a.b.c", None),
    ("*.md", None),
    ("10**(-d)/100", None),
    ("'{...}'", None),
]


def _write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _track(root: Path) -> None:
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)


class CheckDocRefsTest(TempDirTestCase):
    """A git repo with a Makefile, a Typer console script, scripts and clean docs."""

    def setUp(self) -> None:
        """Build the fixture repo under the isolated git environment."""
        super().setUp()
        os.environ.clear()
        os.environ.update(isolated_git_env(self.tmp_path))
        self.repo = self.tmp_path / "repo"
        for relative, text in FILES.items():
            _write(self.repo, relative, text)
        _write(self.repo, "README.md", CLEAN_README)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        _track(self.repo)

    def _check(self, root: Path) -> tuple[int, str]:
        code, out, err = self.capture(refs.main, ["--root", str(root)])
        assert isinstance(code, int)
        return code, out + err

    def _with_readme(self, extra: str) -> Path:
        _write(self.repo, "README.md", CLEAN_README + extra)
        return self.repo

    def test_clean_repo_passes(self) -> None:
        code, output = self._check(self.repo)
        self.assertEqual(code, 0, output)
        self.assertIn("check_doc_refs: ok (2 docs", output)

    def test_missing_path_fails_with_file_and_line(self) -> None:
        code, output = self._check(self._with_readme("\nGone: `scripts/removed.py`.\n"))
        self.assertEqual(code, 1)
        self.assertIn("README.md:5: path `scripts/removed.py` does not exist", output)

    def test_missing_bare_file_name_with_known_extension_fails(self) -> None:
        code, output = self._check(self._with_readme("`nowhere.toml`\n"))
        self.assertEqual(code, 1)
        self.assertIn("path `nowhere.toml`", output)

    def test_gitignored_missing_path_is_not_reported(self) -> None:
        code, output = self._check(self._with_readme("`runs/latest/summary.txt`\n"))
        self.assertEqual(code, 0, output)

    def test_missing_directory_matched_only_by_a_directory_pattern_is_not_reported(
        self,
    ) -> None:
        _write(self.repo, ".gitignore", "runs/\nbuild/out/\n")
        _track(self.repo)
        code, output = self._check(self._with_readme("Built into `build/out`.\n"))
        self.assertEqual(code, 0, output)

    def test_path_beyond_an_ignored_symlink_does_not_hide_other_ignored_paths(
        self,
    ) -> None:
        shared = self.tmp_path / "shared-logs"
        shared.mkdir()
        (self.repo / "logs").symlink_to(shared)
        _write(self.repo, ".gitignore", "runs/\nlogs\n")
        _track(self.repo)
        extra = "`logs/`, `logs/latest/run.json` and `runs/latest/summary.txt`\n"
        code, output = self._check(self._with_readme(extra))
        self.assertEqual(code, 0, output)

    def test_path_beyond_a_tracked_symlink_is_reported(self) -> None:
        shared = self.tmp_path / "shared-logs"
        shared.mkdir()
        (self.repo / "logs").symlink_to(shared)
        _track(self.repo)
        code, output = self._check(self._with_readme("`logs/latest/run.json`\n"))
        self.assertEqual(code, 1)
        self.assertIn("path `logs/latest/run.json` does not exist", output)

    def test_struck_through_reference_is_not_checked(self) -> None:
        code, output = self._check(self._with_readme("~~`scripts/old.py`~~ replaced\n"))
        self.assertEqual(code, 0, output)

    def test_unknown_make_target_fails_by_name(self) -> None:
        code, output = self._check(self._with_readme("`make lint deploy p=x`\n"))
        self.assertEqual(code, 1)
        self.assertIn("make-target `make deploy` is not a target in the Makefile", output)
        self.assertNotIn("make lint`", output)

    def test_make_span_for_another_makefile_is_not_checked(self) -> None:
        code, output = self._check(
            self._with_readme("`make -C sub deploy` `make -o x lint`\n")
        )
        self.assertEqual(code, 0, output)

    def test_flag_missing_from_the_console_script_fails(self) -> None:
        code, output = self._check(self._with_readme("`mini run --force`\n"))
        self.assertEqual(code, 1)
        self.assertIn("flag `--force` is not defined by mini", output)

    def test_unknown_subcommand_fails_by_name(self) -> None:
        code, output = self._check(self._with_readme("`mini report --run-dir x`\n"))
        self.assertEqual(code, 1)
        self.assertIn("subcommand `mini report` is not a subcommand of mini", output)

    def test_flag_of_one_script_is_not_accepted_for_another(self) -> None:
        code, output = self._check(
            self._with_readme("`python scripts/tool.py --run-dir x`\n")
        )
        self.assertEqual(code, 1)
        self.assertIn("flag `--run-dir` is not defined by scripts/tool.py", output)

    def test_missing_script_in_a_command_fails_as_a_path(self) -> None:
        code, output = self._check(self._with_readme("`python3 scripts/gone.py --x`\n"))
        self.assertEqual(code, 1)
        self.assertIn("path `scripts/gone.py` does not exist", output)

    def test_bare_flag_is_checked_against_every_repo_flag(self) -> None:
        code, output = self._check(
            self._with_readme("`--static-only` `--run-dir DIR` `--gone`\n")
        )
        self.assertEqual(code, 1)
        self.assertIn("flag `--gone` is not defined by any command in the repo", output)
        self.assertNotIn("--static-only`", output)

    def test_exemption_silences_its_finding(self) -> None:
        _write(
            self.repo,
            refs.ALLOWLIST,
            "# note\nREADME.md | --gone | an external tool's flag\n",
        )
        code, output = self._check(self._with_readme("`--gone`\n"))
        self.assertEqual(code, 0, output)
        self.assertIn("1 exempted", output)

    def test_stale_exemption_fails_with_its_line(self) -> None:
        _write(self.repo, refs.ALLOWLIST, "\n* | scripts/old.py | removed in 2026\n")
        code, output = self._check(self.repo)
        self.assertEqual(code, 1)
        self.assertIn(
            "docs/doc-refs-allow.txt:2: stale exemption `* | scripts/old.py`", output
        )

    def test_exemption_without_a_reason_is_a_usage_error(self) -> None:
        _write(self.repo, refs.ALLOWLIST, "README.md | --gone |\n")
        code, output = self._check(self.repo)
        self.assertEqual(code, 2)
        self.assertIn("docs/doc-refs-allow.txt:1: expected", output)

    def test_repo_without_docs_fails_closed(self) -> None:
        subprocess.run(
            ["git", "rm", "-q", "--cached", "README.md", "docs/guide.md"],
            cwd=self.repo,
            check=True,
        )
        code, output = self._check(self.repo)
        self.assertEqual(code, 1)
        self.assertIn("read 0 docs", output)

    def test_non_git_directory_is_a_usage_error(self) -> None:
        outside = self.tmp_path / "outside"
        outside.mkdir()
        code, output = self._check(outside)
        self.assertEqual(code, 2)
        self.assertIn("is not a git checkout", output)


class PathCandidateTest(unittest.TestCase):
    """Which tokens are path-shaped, and the pattern each one becomes."""

    def test_path_candidate_shapes(self) -> None:
        for token, expected in PATH_SHAPES:
            with self.subTest(token=token):
                self.assertEqual(path_candidate(token), expected)


if __name__ == "__main__":
    unittest.main()
