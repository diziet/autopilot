"""scripts/branches_gc.py: classification and the delete-only-merged rule."""

from __future__ import annotations

import os
import unittest
from pathlib import Path

import branches_gc
from gitfixture import GitRepoTestCase


def _branch(name: str, **overrides: object) -> branches_gc.Branch:
    fields: dict[str, object] = {
        "is_merged": False,
        "upstream_gone": False,
        "worktree": None,
        "has_open_pr": False,
    }
    fields.update(overrides)
    return branches_gc.Branch(name=name, **fields)


class ClassifyTest(unittest.TestCase):
    """Each branch lands in exactly one class, in priority order."""

    def test_classify_puts_each_branch_in_exactly_one_class(self) -> None:
        branches = [
            _branch("main", is_merged=True),
            _branch("feat/wt", is_merged=True, worktree="/tmp/wt"),
            _branch("feat/pr", has_open_pr=True),
            _branch("feat/done", is_merged=True),
            _branch("feat/gone", upstream_gone=True),
            _branch("feat/wip"),
        ]
        groups = branches_gc.classify(branches)
        names = {klass: [b.name for b in items] for klass, items in groups.items()}
        self.assertEqual(
            names,
            {
                "checked-out": ["feat/wt"],
                "open-pr": ["feat/pr"],
                "merged": ["feat/done"],
                "superseded": ["feat/gone"],
                "active": ["feat/wip"],
            },
        )

    def test_checked_out_wins_over_merged_and_open_pr_wins_over_merged(self) -> None:
        groups = branches_gc.classify(
            [
                _branch("a", is_merged=True, worktree="/x"),
                _branch("b", is_merged=True, has_open_pr=True),
            ]
        )
        self.assertEqual(groups["merged"], [])
        self.assertEqual([b.name for b in groups["checked-out"]], ["a"])
        self.assertEqual([b.name for b in groups["open-pr"]], ["b"])


class GatherTest(GitRepoTestCase):
    """gather() reads real git state; --delete removes only merged branches."""

    def _fake_gh(self, open_branches: list[str]) -> None:
        listing = ",".join(f'{{"headRefName":"{b}"}}' for b in open_branches)
        bin_dir = self.tmp_path / "bin"
        self.write_executable(bin_dir / "gh", f"#!/bin/sh\necho '[{listing}]'\n")
        self.prepend_path(bin_dir)

    def test_gather_reads_git_state(self) -> None:
        self.repo.git("branch", "feat/merged", "origin/main")
        self.repo.git("switch", "-q", "-c", "feat/open")
        self.repo.commit_file("o.txt", "o\n", "open")
        self.repo.git("switch", "-q", "-c", "feat/active")
        self.repo.commit_file("a.txt", "a\n", "active")
        self.repo.git("push", "-q", "-u", "origin", "feat/active")
        self.repo.git("push", "-q", "origin", "--delete", "feat/active")
        self.repo.git("fetch", "-q", "--prune", "origin")
        self.repo.git("switch", "-q", "main")
        self._fake_gh(["feat/open"])
        groups = branches_gc.classify(branches_gc.gather(self.repo.clone))
        names = {klass: sorted(b.name for b in items) for klass, items in groups.items()}
        self.assertEqual(names["merged"], ["feat/merged"])
        self.assertEqual(names["open-pr"], ["feat/open"])
        self.assertEqual(names["superseded"], ["feat/active"])
        self.assertEqual(names["checked-out"], [])

    def test_gather_without_gh_keeps_unmerged_branches_active(self) -> None:
        empty_bin = self.tmp_path / "empty-bin"
        empty_bin.mkdir()
        os.environ["PATH"] = f"{empty_bin}:/usr/bin:/bin"
        self.repo.git("switch", "-q", "-c", "feat/x")
        self.repo.commit_file("x.txt", "x\n", "x")
        self.repo.git("switch", "-q", "main")
        groups, _, err = self.capture(
            lambda: branches_gc.classify(branches_gc.gather(self.repo.clone))
        )
        self.assertEqual([b.name for b in groups["active"]], ["feat/x"])
        self.assertIn("gh unavailable", err)

    def test_delete_removes_only_the_merged_class(self) -> None:
        self.repo.git("branch", "feat/merged", "origin/main")
        self.repo.git("switch", "-q", "-c", "feat/keep")
        self.repo.commit_file("k.txt", "k\n", "keep")
        self.repo.git("switch", "-q", "main")
        self._fake_gh([])
        code, _, _ = self.capture(
            branches_gc.main, ["--root", str(self.repo.clone), "--delete"]
        )
        self.assertEqual(code, 0)
        remaining = self.repo.git(
            "for-each-ref", "refs/heads", "--format=%(refname:short)"
        ).stdout.split()
        self.assertEqual(sorted(remaining), ["feat/keep", "main"])

    def test_report_only_by_default(self) -> None:
        self.repo.git("branch", "feat/merged", "origin/main")
        self._fake_gh([])
        code, out, _ = self.capture(branches_gc.main, ["--root", str(self.repo.clone)])
        self.assertEqual(code, 0)
        self.assertIn("merged (1):", out)
        self.assertIn("report only", out)
        branch_check = self.repo.git(
            "show-ref", "--verify", "--quiet", "refs/heads/feat/merged", check=False
        )
        self.assertEqual(branch_check.returncode, 0)

    def test_main_rejects_non_repo(self) -> None:
        empty = self.tmp_path / "not-a-repo"
        empty.mkdir()
        code, _, _ = self.capture(branches_gc.main, ["--root", str(empty)])
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
