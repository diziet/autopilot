"""scripts/check_gate_wiring.py: inject each defect, see it fail by name, fix it, pass."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import check_gate_wiring as wiring
from gitfixture import REPO_ROOT, TempDirTestCase

KNOWN_BATS = frozenset({"tests/test_alpha.bats"})
KNOWN_TOOLING = frozenset({"test_tool"})
MAKEFILE = (
    "check: ## Blocking gate: lint and test\n\t@make lint & make test\n"
    "lint: ## Blocking gate: shellcheck\n\tshellcheck x.sh\n"
    "test: ## Blocking gate: bats\n\tbats tests/\n"
    "gate: ## Blocking gate: everything\n\tbash scripts/gate.sh\n"
    "helper: ## Advisory: uses tool\n\tpython3 scripts/tool.py\n"
)
GATE_SH = '#!/bin/sh\nstages="check"\nfor s in $stages; do make -s $s; done\n'


class WiringTestCase(TempDirTestCase):
    """A repo shaped like autopilot: Makefile, scripts, one bats file, one tooling test."""

    def setUp(self) -> None:
        """Build the mini repo in the test's temp dir."""
        super().setUp()
        root = self.tmp_path
        (root / "Makefile").write_text(MAKEFILE)
        (root / "scripts").mkdir()
        (root / "scripts" / "gate.sh").write_text(GATE_SH)
        (root / "scripts" / "tool.py").write_text("print('tool')\n")
        (root / "scripts" / "remove-crontab-entries.sh").write_text("#!/bin/sh\n")
        (root / "tests" / "tooling").mkdir(parents=True)
        (root / "tests" / "test_alpha.bats").write_text('@test "alpha" {\n  true\n}\n')
        (root / "tests" / "tooling" / "test_tool.py").write_text(
            "import unittest\n\nclass ToolTest(unittest.TestCase):\n"
            "    def test_tool(self) -> None:\n        self.assertTrue(True)\n"
        )
        self.root = root

    def bats_problems(self) -> list[str]:
        return wiring.check_bats_files(self.root, KNOWN_BATS)

    def tooling_problems(self) -> list[str]:
        return wiring.check_tooling_tests(self.root, sys.executable, KNOWN_TOOLING)


class BatsFilesTest(WiringTestCase):
    """(a) bats tests outside tests/*.bats never run, and the known set must exist."""

    def test_clean_fixture_has_no_bats_problems(self) -> None:
        self.assertEqual(self.bats_problems(), [])

    def test_bats_file_in_a_subdirectory_fails_by_name_then_passes_when_moved(self) -> None:
        nested = self.root / "tests" / "unit" / "test_nested.bats"
        nested.parent.mkdir()
        nested.write_text('@test "nested" {\n  true\n}\n')
        self.assertEqual(
            self.bats_problems(),
            ["bats tests that `bats tests/` does not run: tests/unit/test_nested.bats"],
        )
        nested.rename(self.root / "tests" / "test_nested.bats")
        self.assertEqual(self.bats_problems(), [])

    def test_bats_tests_in_a_non_bats_file_fail(self) -> None:
        (self.root / "tests" / "test_beta.sh").write_text('@test "beta" {\n  true\n}\n')
        self.assertEqual(
            self.bats_problems(), ["bats tests that `bats tests/` does not run: tests/test_beta.sh"]
        )

    def test_missing_known_bats_file_fails(self) -> None:
        (self.root / "tests" / "test_alpha.bats").unlink()
        self.assertEqual(self.bats_problems(), ["known bats file missing: tests/test_alpha.bats"])


class ToolingTestsTest(WiringTestCase):
    """(b) Every tooling test module is collected by unittest."""

    def test_clean_fixture_has_no_tooling_problems(self) -> None:
        self.assertEqual(self.tooling_problems(), [])

    def test_uncollected_module_fails_by_name_then_passes_when_renamed(self) -> None:
        stray = self.root / "tests" / "tooling" / "tool_checks.py"
        stray.write_text(
            "import unittest\n\nclass StrayTest(unittest.TestCase):\n"
            "    def test_stray(self) -> None:\n        pass\n"
        )
        problems = self.tooling_problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("tests/tooling/tool_checks.py", problems[0])
        stray.rename(self.root / "tests" / "tooling" / "test_stray.py")
        self.assertEqual(self.tooling_problems(), [])

    def test_module_imported_by_a_collected_module_counts_as_collected(self) -> None:
        (self.root / "tests" / "tooling" / "shared_cases.py").write_text(
            "import unittest\n\nclass SharedCases(unittest.TestCase):\n"
            "    def test_shared(self) -> None:\n        pass\n"
        )
        (self.root / "tests" / "tooling" / "test_tool.py").write_text(
            "from shared_cases import SharedCases\n\nclass ToolTest(SharedCases):\n    pass\n"
        )
        self.assertEqual(self.tooling_problems(), [])

    def test_import_error_is_reported(self) -> None:
        (self.root / "tests" / "tooling" / "test_broken.py").write_text("def broken(:\n")
        problems = self.tooling_problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("unittest collection failed", problems[0])

    def test_missing_known_module_fails(self) -> None:
        problems = wiring.check_tooling_tests(
            self.root, sys.executable, frozenset({"test_missing"})
        )
        self.assertEqual(
            problems, ["known tooling test module missing from collection: test_missing"]
        )


class ScriptsReferencedTest(WiringTestCase):
    """(c) No orphan scripts; operator-script exemptions must still match a file."""

    def test_orphan_script_fails_by_name_then_passes_when_referenced(self) -> None:
        (self.root / "scripts" / "orphan.py").write_text("print('x')\n")
        self.assertEqual(
            wiring.check_scripts_referenced(self.root),
            ["orphan script (not referenced by Makefile, hooks or scripts): scripts/orphan.py"],
        )
        (self.root / "Makefile").write_text(
            MAKEFILE + "orphan: ## Advisory\n\tpython3 scripts/orphan.py\n"
        )
        self.assertEqual(wiring.check_scripts_referenced(self.root), [])

    def test_script_referenced_only_by_python_import_is_referenced(self) -> None:
        (self.root / "scripts" / "helpers_mod.py").write_text("X = 1\n")
        (self.root / "scripts" / "tool.py").write_text("from helpers_mod import X\nprint(X)\n")
        self.assertEqual(wiring.check_scripts_referenced(self.root), [])

    def test_reference_inside_a_comment_does_not_count(self) -> None:
        (self.root / "scripts" / "ghost.py").write_text("print('x')\n")
        (self.root / "Makefile").write_text(MAKEFILE + "# see scripts/ghost.py\n")
        self.assertEqual(len(wiring.check_scripts_referenced(self.root)), 1)

    def test_stale_operator_script_exemption_fails(self) -> None:
        (self.root / "scripts" / "remove-crontab-entries.sh").unlink()
        self.assertEqual(
            wiring.check_scripts_referenced(self.root),
            [
                "stale operator-script exemption: "
                "scripts/remove-crontab-entries.sh does not exist"
            ],
        )


class BlockingTargetsTest(WiringTestCase):
    """(d) Every Blocking-gate target is reached from gate.sh, directly or through make calls."""

    def test_targets_reached_through_a_recipe_count_as_wired(self) -> None:
        self.assertEqual(wiring.check_blocking_targets_wired(self.root), [])

    def test_unwired_blocking_target_fails_then_passes_when_added_to_gate(self) -> None:
        (self.root / "Makefile").write_text(
            MAKEFILE + "test-tooling: ## Blocking gate: unittest\n\tpython3 -m unittest\n"
        )
        problems = wiring.check_blocking_targets_wired(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("'test-tooling'", problems[0])
        (self.root / "scripts" / "gate.sh").write_text(
            GATE_SH.replace('stages="check"', 'stages="test-tooling check"')
        )
        self.assertEqual(wiring.check_blocking_targets_wired(self.root), [])

    def test_hyphenated_name_does_not_wire_its_suffix(self) -> None:
        (self.root / "scripts" / "gate.sh").write_text(
            GATE_SH.replace('stages="check"', 'stages="gate-wiring-check"')
        )
        problems = wiring.check_blocking_targets_wired(self.root)
        self.assertEqual(
            sorted(p.split("'")[1] for p in problems), ["check", "lint", "test"]
        )

    def test_make_calls_skip_options_and_assignments(self) -> None:
        recipe = '\t@make lint & pid=$$!; $(MAKE) -C "$(ROOT)" -s check V=1\n'
        self.assertEqual(wiring.make_calls(recipe), {"lint", "check"})

    def test_blocking_targets_are_parsed_from_help_comments(self) -> None:
        self.assertEqual(wiring.blocking_targets(MAKEFILE), ["check", "lint", "test", "gate"])


class CliTest(WiringTestCase):
    """The verdict is the exit code: 0 clean, 1 on a problem, 2 outside a repo root."""

    def test_cli_exit_codes(self) -> None:
        original = (wiring.KNOWN_BATS_FILES, wiring.KNOWN_TOOLING_MODULES)
        wiring.KNOWN_BATS_FILES, wiring.KNOWN_TOOLING_MODULES = KNOWN_BATS, KNOWN_TOOLING
        self.addCleanup(self._restore_known, original)
        code, out, _ = self.capture(wiring.main, ["--root", str(self.root)])
        self.assertEqual(code, 0)
        self.assertIn("check_gate_wiring: ok", out)
        (self.root / "scripts" / "orphan.py").write_text("")
        code, _, err = self.capture(wiring.main, ["--root", str(self.root)])
        self.assertEqual(code, 1)
        self.assertIn("FAIL orphan script", err)
        code, _, _ = self.capture(wiring.main, ["--root", str(self.root / "nowhere")])
        self.assertEqual(code, 2)

    @staticmethod
    def _restore_known(original: tuple[frozenset[str], frozenset[str]]) -> None:
        wiring.KNOWN_BATS_FILES, wiring.KNOWN_TOOLING_MODULES = original


class RealRepoTest(unittest.TestCase):
    """The checks pass on this repository itself."""

    def test_real_repo_is_fully_wired(self) -> None:
        self.assertEqual(wiring.run_all(Path(REPO_ROOT), sys.executable), [])


if __name__ == "__main__":
    unittest.main()
