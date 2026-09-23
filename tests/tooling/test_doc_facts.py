"""scripts/doc_facts.py and its readers: a stale fact fails, regeneration fixes it.

A unittest port of tests/tooling/test_doc_facts.py in llm-reliability-benchmark, where the
check comes from. The test names, fixture repo and assertions are the same.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from typing import TYPE_CHECKING

import doc_facts
from doc_facts_sources import (
    Fact,
    FactError,
    count_distinct,
    makefile_recipe,
    pyproject_value,
    regex_group,
)
from gitfixture import TempDirTestCase, isolated_git_env

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

REGISTRY = {
    "answer": Fact(
        "the ANSWER file", lambda root: (root / "ANSWER").read_text().strip()
    ),
    "double": Fact(
        "twice the ANSWER", lambda root: 2 * int((root / "ANSWER").read_text())
    ),
}
DOC = (
    "The answer is <!-- fact:answer -->42<!-- /fact -->.\n"
    "Twice that is <!-- fact:double -->84<!-- /fact -->.\n"
)
REGISTRY_FILE = """from doc_facts_sources import Fact, read_text

FACTS = {"answer": Fact("ANSWER", lambda root: read_text(root, "ANSWER").strip())}
"""
SHAPE_ERRORS: list[tuple[Callable[[Path], object], str]] = [
    (lambda root: regex_group(root, "NOTES", r"^(nothing)$"), "has no line matching"),
    (
        lambda root: count_distinct(root, "NOTES", r"^(nothing)$"),
        "has no line matching",
    ),
    (lambda root: makefile_recipe(root, "deploy"), "has no `deploy` target"),
    (lambda root: pyproject_value(root, "tool.y"), "has no `tool.y`"),
]


class DocFactsTest(TempDirTestCase):
    """A git repo with one marked doc whose values match ANSWER."""

    def setUp(self) -> None:
        """Build the fixture repo under the isolated git environment."""
        super().setUp()
        os.environ.clear()
        os.environ.update(isolated_git_env(self.tmp_path))
        self.repo = self.tmp_path / "repo"
        self.repo.mkdir()
        (self.repo / "ANSWER").write_text("42\n")
        (self.repo / "README.md").write_text(DOC)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)

    def _run(self, mode: str) -> tuple[object, str, str]:
        return self.capture(doc_facts.run, self.repo, REGISTRY, mode)

    def _readme(self) -> str:
        return (self.repo / "README.md").read_text()

    def test_current_values_pass_the_read_only_check(self) -> None:
        code, out, _ = self._run("check")
        self.assertEqual(code, 0)
        self.assertIn("doc_facts: ok (2 markers in 1 docs)", out)

    def test_stale_value_fails_with_line_and_diff_and_leaves_the_file(self) -> None:
        (self.repo / "ANSWER").write_text("43\n")
        code, _, err = self._run("check")
        self.assertEqual(code, 1)
        self.assertIn("README.md:1: fact 'answer' states '42'; the tree says '43'", err)
        self.assertIn("README.md:2: fact 'double' states '84'; the tree says '86'", err)
        self.assertIn("-The answer is <!-- fact:answer -->42<!-- /fact -->.", err)
        self.assertIn("+The answer is <!-- fact:answer -->43<!-- /fact -->.", err)
        self.assertEqual(self._readme(), DOC)

    def test_write_rewrites_stale_values_and_names_each_file(self) -> None:
        (self.repo / "ANSWER").write_text("7\n")
        code, out, err = self._run("write")
        self.assertEqual(code, 0, err)
        self.assertIn("doc_facts: rewrote README.md", out)
        self.assertIn("<!-- fact:answer -->7<!-- /fact -->", self._readme())
        self.assertIn("<!-- fact:double -->14<!-- /fact -->", self._readme())

    def test_write_rewrites_nothing_when_values_are_current(self) -> None:
        code, out, _ = self._run("write")
        self.assertEqual(code, 0)
        self.assertNotIn("rewrote", out)

    def test_fix_stale_rewrites_then_fails(self) -> None:
        (self.repo / "ANSWER").write_text("5\n")
        code, out, err = self._run("fix-stale")
        self.assertEqual(code, 1)
        self.assertIn("doc_facts: rewrote README.md", out)
        self.assertIn("rewrote them; review and stage", err)
        self.assertIn("<!-- fact:answer -->5<!-- /fact -->", self._readme())

    def test_markers_in_code_spans_and_fences_are_examples(self) -> None:
        example = (
            "Write `<!-- fact:nope -->1<!-- /fact -->`.\n\n"
            "```\n<!-- fact:nope -->2<!-- /fact -->\n```\n"
        )
        (self.repo / "README.md").write_text(DOC + example)
        (self.repo / "ANSWER").write_text("1\n")
        code, _, err = self._run("write")
        self.assertEqual(code, 0, err)
        self.assertTrue(self._readme().endswith(example))

    def test_marker_at_the_start_of_a_line_fails(self) -> None:
        (self.repo / "README.md").write_text(
            DOC + "- <!-- fact:answer -->42<!-- /fact --> items\n"
        )
        code, _, err = self._run("write")
        self.assertEqual(code, 1)
        self.assertIn("README.md:3: fact marker starts a line", err)

    def test_unknown_fact_fails_by_file_and_line_without_writing(self) -> None:
        (self.repo / "ANSWER").write_text("9\n")
        (self.repo / "README.md").write_text(
            DOC + "Also <!-- fact:missing -->0<!-- /fact -->.\n"
        )
        code, _, err = self._run("write")
        self.assertEqual(code, 1)
        self.assertIn(
            "README.md:3: unknown fact 'missing'; registered: answer, double", err
        )
        self.assertIn("<!-- fact:answer -->42<!-- /fact -->", self._readme())

    def test_registered_fact_without_a_marker_fails(self) -> None:
        (self.repo / "README.md").write_text(
            "The answer is <!-- fact:answer -->42<!-- /fact -->.\n"
        )
        code, _, err = self._run("check")
        self.assertEqual(code, 1)
        self.assertIn(
            "registered fact 'double' has no marker in any tracked .md file", err
        )

    def test_missing_source_fails_with_the_fact_name(self) -> None:
        registry = {
            "gone": Fact("the GONE file", lambda root: regex_group(root, "GONE", "(x)"))
        }
        (self.repo / "README.md").write_text("Gone: <!-- fact:gone -->x<!-- /fact -->.\n")
        code, _, err = self.capture(doc_facts.run, self.repo, registry, "check")
        self.assertEqual(code, 1)
        self.assertIn("fact 'gone' (the GONE file): GONE does not exist", err)

    def test_multi_line_value_is_rejected(self) -> None:
        registry = {"answer": Fact("two lines", lambda root: "a\nb")}
        (self.repo / "README.md").write_text(
            "Value <!-- fact:answer -->a<!-- /fact -->.\n"
        )
        code, _, err = self.capture(doc_facts.run, self.repo, registry, "write")
        self.assertEqual(code, 1)
        self.assertIn("multi-line or marker-breaking value", err)

    def test_untracked_and_excluded_docs_are_ignored(self) -> None:
        stale = "Old <!-- fact:unknown -->1<!-- /fact -->.\n"
        (self.repo / "tests" / "fixtures").mkdir(parents=True)
        (self.repo / "tests" / "fixtures" / "doc.md").write_text(stale)
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        (self.repo / "untracked.md").write_text(stale)
        code, _, err = self._run("check")
        self.assertEqual(code, 0, err)

    def test_main_loads_the_registry_under_the_root(self) -> None:
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts" / "doc_facts_registry.py").write_text(REGISTRY_FILE)
        (self.repo / "README.md").write_text("A <!-- fact:answer -->0<!-- /fact -->.\n")
        code, _, _ = self.capture(
            doc_facts.main, ["--root", str(self.repo), "--write"]
        )
        self.assertEqual(code, 0)
        self.assertIn("<!-- fact:answer -->42<!-- /fact -->", self._readme())

    def test_main_without_a_registry_fails(self) -> None:
        code, _, err = self.capture(doc_facts.main, ["--root", str(self.repo)])
        self.assertEqual(code, 1)
        self.assertIn("scripts/doc_facts_registry.py does not exist", err)

    def test_main_outside_a_git_checkout_is_a_usage_error(self) -> None:
        outside = self.tmp_path / "outside"
        outside.mkdir()
        code, _, err = self.capture(doc_facts.main, ["--root", str(outside)])
        self.assertEqual(code, 2)
        self.assertIn("is not a git checkout", err)


class FactReaderTest(TempDirTestCase):
    """The readers in doc_facts_sources.py return values or raise FactError."""

    def test_readers_return_values_from_their_sources(self) -> None:
        root = self.tmp_path
        (root / "NOTES").write_text("# v1.2\n## PR 1\n## PR 2\n## PR 2\n")
        (root / "Makefile").write_text("run:\n\tpython scripts/run.py\n")
        (root / "pyproject.toml").write_text("[tool.x]\nlimit = 7\n")
        self.assertEqual(regex_group(root, "NOTES", r"^# v(\S+)$"), "1.2")
        self.assertEqual(count_distinct(root, "NOTES", r"^## PR (\d+)$"), 2)
        self.assertEqual(makefile_recipe(root, "run"), ["python scripts/run.py"])
        self.assertEqual(pyproject_value(root, "tool.x.limit"), 7)

    def test_readers_raise_fact_error_when_the_source_changed_shape(self) -> None:
        root = self.tmp_path
        (root / "NOTES").write_text("text\n")
        (root / "Makefile").write_text("run:\n\ttrue\n")
        (root / "pyproject.toml").write_text("[tool.x]\n")
        for reader, message in SHAPE_ERRORS:
            with self.subTest(message=message), self.assertRaisesRegex(
                FactError, message
            ):
                reader(root)


if __name__ == "__main__":
    unittest.main()
