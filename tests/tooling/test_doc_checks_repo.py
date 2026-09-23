"""This repo's doc checks: the refs scan reaches known references, each fact computes.

The engine tests (test_check_doc_refs.py, test_doc_facts.py, test_doc_common.py) are unittest
ports of the llm-reliability-benchmark tests. This file names references and facts that exist
only here, so a broken scanner or registry cannot pass by checking nothing.
"""

from __future__ import annotations

import unittest

import check_doc_refs as refs
from doc_facts_registry import FACTS
from doc_refs_cli import ProgramIndex
from gitfixture import REPO_ROOT

FACT_SHAPES = {
    "max-network-retries": r"[1-9]\d*",
    "max-diff-kb": r"[1-9]\d*",
    "diff-sample-bytes": r"[1-9]\d{0,2}(,\d{3})*",
    "self-update-interval": r"\d+",
}


class DocChecksRepoTest(unittest.TestCase):
    """The doc checks against this repo's own docs, scripts and registry."""

    def test_refs_scan_checks_a_named_minimum_set_of_references(self) -> None:
        checker = refs.Checker(REPO_ROOT)
        for doc in ("README.md", "CLAUDE.md"):
            checker.check_doc(doc)
        self.assertLessEqual(
            {
                "make gate",
                "make merge",
                "make test",
                "bin/autopilot-dispatch",
                "lib/config.sh",
                "tests/test_*.bats",
                "docs/writing-style.md",
            },
            set(checker.checked),
        )

    def test_bin_entry_points_define_their_case_pattern_flags(self) -> None:
        index = ProgramIndex(REPO_ROOT)
        self.assertLessEqual(
            {"--account", "--dispatcher-account", "--reviewer-account", "--interval"},
            index.all_flags(),
        )
        schedule = index.script("bin/autopilot-schedule")
        self.assertIn("--dispatcher-account", schedule.flags)

    def test_registered_fact_computes_a_well_formed_value(self) -> None:
        for name, shape in FACT_SHAPES.items():
            with self.subTest(fact=name):
                self.assertRegex(str(FACTS[name].compute(REPO_ROOT)), rf"^{shape}$")

    def test_every_registered_fact_has_a_shape_test(self) -> None:
        self.assertEqual(set(FACTS), set(FACT_SHAPES))


if __name__ == "__main__":
    unittest.main()
