"""scripts/doc_common.py: code spans, code regions, doc listing and Makefile rules.

A unittest port of tests/tooling/test_doc_common.py in llm-reliability-benchmark, where the
check comes from. The test names, inputs and assertions are the same.
"""

from __future__ import annotations

import os
import subprocess
import unittest

from doc_common import code_regions, code_spans, list_docs, makefile_rules
from gitfixture import TempDirTestCase, isolated_git_env


def _texts(markdown: str) -> list[str]:
    return [span.text for span in code_spans(markdown)]


class CodeSpanTest(unittest.TestCase):
    """The Markdown scanner: fences, spans, comments and strikethrough."""

    def test_code_spans_skip_fenced_blocks(self) -> None:
        markdown = "`a`\n\n```bash\nmake `b`\n```\n\n~~~\n`c`\n~~~\n`d`\n"
        self.assertEqual(_texts(markdown), ["a", "d"])

    def test_code_spans_skip_an_indented_fence_inside_a_list(self) -> None:
        markdown = "- step:\n\n    ```\n    `hidden`\n    ```\n- `shown`\n"
        self.assertEqual(_texts(markdown), ["shown"])

    def test_code_spans_report_the_line_of_the_opening_backtick(self) -> None:
        markdown = "title\n\ntext `one` and\n`two`\n"
        self.assertEqual(
            [(s.line, s.text) for s in code_spans(markdown)], [(3, "one"), (4, "two")]
        )

    def test_double_backtick_span_keeps_an_inner_backtick_and_strips_padding(self) -> None:
        self.assertEqual(_texts("``  a ` b  ``"), [" a ` b "])
        self.assertEqual(_texts("`` `x` ``"), ["`x`"])

    def test_backtick_run_without_a_closer_of_equal_width_is_literal(self) -> None:
        self.assertEqual(_texts("a `` b `c`"), ["c"])
        self.assertEqual(_texts("a ` b\n\n`c`"), ["c"])

    def test_escaped_backtick_does_not_open_a_span(self) -> None:
        self.assertEqual(_texts(r"\`x and `y`"), ["y"])

    def test_code_span_inside_an_html_comment_is_skipped(self) -> None:
        markdown = "<!-- `hidden`\nstill hidden -->`shown`"
        self.assertEqual(_texts(markdown), ["shown"])

    def test_comment_opener_inside_a_code_span_does_not_hide_the_rest(self) -> None:
        self.assertEqual(_texts("`<!--` then `after`"), ["<!--", "after"])

    def test_struck_span_is_marked_even_across_a_line_break(self) -> None:
        markdown = "~~`old` and\n`older`~~ now `new`\n"
        self.assertEqual(
            [(s.text, s.is_struck) for s in code_spans(markdown)],
            [("old", True), ("older", True), ("new", False)],
        )

    def test_strikethrough_does_not_cross_a_blank_line(self) -> None:
        markdown = "~~ unclosed `a`\n\n`b` ~~x~~\n"
        self.assertEqual(
            [(s.text, s.is_struck) for s in code_spans(markdown)],
            [("a", False), ("b", False)],
        )

    def test_code_regions_cover_fences_and_inline_spans(self) -> None:
        markdown = "x `a` y\n```\nz\n```\n"
        regions = code_regions(markdown)
        covered = "".join(markdown[start:end] for start, end in regions)
        self.assertEqual(covered, "`a`" + "```\nz\n```\n")


class DocListingAndMakefileTest(TempDirTestCase):
    """Tracked-doc listing in a throwaway repo, and Makefile rule parsing."""

    def test_list_docs_skips_untracked_excluded_and_symlinked_docs(self) -> None:
        os.environ.clear()
        os.environ.update(isolated_git_env(self.tmp_path))
        root = self.tmp_path / "repo"
        for rel in ("README.md", "docs/a.md", "tests/fixtures/f.md", "pkg/data/d.md"):
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text("# x\n")
        (root / "AGENTS.md").symlink_to("README.md")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        (root / "untracked.md").write_text("# y\n")
        self.assertEqual(list_docs(root), ["README.md", "docs/a.md"])

    def test_makefile_rules_read_targets_recipes_and_includes(self) -> None:
        (self.tmp_path / "Makefile").write_text(
            ".PHONY: a b\nVAR := x\nFLAG ?= y\ninclude extra.mk\n"
            "a b: dep ## two targets\n\techo one \\\n\t  continued\n"
            "%.o: %.c\n\tcc\n$(VAR)-x:\n\ttrue\n"
            "define block\nhidden: rule\nendef\n"
        )
        (self.tmp_path / "extra.mk").write_text("c:\n\techo c\n")
        rules = makefile_rules(self.tmp_path)
        self.assertEqual(sorted(rules), ["a", "b", "c"])
        self.assertEqual(rules["a"], ["echo one  \t  continued"])
        self.assertEqual(rules["c"], ["echo c"])

    def test_makefile_recipe_continues_through_conditionals(self) -> None:
        (self.tmp_path / "Makefile").write_text(
            "check:\nifeq ($(X),)\n\trun default\nelse\n\trun other\nendif\n"
            "X = 1\n\tnot a recipe\n"
        )
        self.assertEqual(
            makefile_rules(self.tmp_path)["check"], ["run default", "run other"]
        )

    def test_makefile_rules_are_empty_without_a_makefile(self) -> None:
        self.assertEqual(makefile_rules(self.tmp_path), {})


if __name__ == "__main__":
    unittest.main()
