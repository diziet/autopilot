"""scripts/merge.py: refusal paths, dry run and the gh merge call (gh stubbed)."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator
from unittest import mock

import gate_lock as gate_lock_module
import merge
import merge_gate
from gitfixture import NO_HOOKS, GitRepoTestCase

FAKE_GH = """#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$FAKE_GH_VIEW_JSON" ;;
  "pr merge") printf '%s\\n' "$*" >> "$FAKE_GH_MERGE_LOG" ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
"""


class MergeTestCase(GitRepoTestCase):
    """PR-shaped fixture: feat/x pushed to origin, gh stubbed, gate stubbed to pass."""

    @classmethod
    def setUpClass(cls) -> None:
        """Write the fake gh once per class; its first run is the slow one on macOS."""
        super().setUpClass()
        cls._gh_dir = tempfile.TemporaryDirectory(prefix="autopilot-fake-gh-")
        gh = Path(cls._gh_dir.name) / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

    @classmethod
    def tearDownClass(cls) -> None:
        """Remove the fake gh."""
        cls._gh_dir.cleanup()
        super().tearDownClass()

    def setUp(self) -> None:
        """Push feat/x, put the fake gh first on PATH and make the preview gate a no-op."""
        super().setUp()
        self.prepend_path(Path(self._gh_dir.name))
        self.view_json = self.tmp_path / "pr.json"
        self.merge_log = self.tmp_path / "merge.log"
        os.environ["FAKE_GH_VIEW_JSON"] = str(self.view_json)
        os.environ["FAKE_GH_MERGE_LOG"] = str(self.merge_log)
        os.environ[merge.GATE_CMD_ENV] = "true"
        self.repo.git("switch", "-q", "-c", "feat/x")
        self.head_sha = self.repo.commit_file("feature.sh", "X=1\n", "feature")
        self.repo.git("push", "-q", "-u", "origin", "feat/x")
        self.repo.git("switch", "-q", "main")
        self.set_pr()

    def set_pr(self, **overrides: str) -> None:
        """Write the JSON the fake `gh pr view` prints."""
        data = {
            "headRefName": "feat/x",
            "headRefOid": self.head_sha,
            "baseRefName": "main",
            "state": "OPEN",
            "mergeable": "MERGEABLE",
        }
        data.update(overrides)
        self.view_json.write_text(json.dumps(data))

    def run_merge(self, *args: str, root: Path | None = None) -> tuple[int, str, str]:
        """Run merge.main for PR 7; return (exit code, stdout, stderr)."""
        argv = ["--pr", "7", "--root", str(root or self.repo.clone), *args]
        code, out, err = self.capture(merge.main, argv)
        return int(code), out, err

    def patch_attr(self, target: object, name: str, value: object) -> None:
        """Replace `target.name` with `value` for the rest of the test."""
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)


class MergeRefusalTest(MergeTestCase):
    """Every guard refuses closed and names its reason."""

    def test_refuses_dirty_tree(self) -> None:
        (self.repo.clone / "untracked.txt").write_text("x\n")
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("refused (closed)", err)
        self.assertIn("untracked.txt", err)

    def test_refuses_divergent_local_main(self) -> None:
        (self.repo.clone / "local.txt").write_text("x\n")
        self.repo.git("add", "local.txt")
        self.repo.git(*NO_HOOKS, "commit", "-q", "-m", "stranded on main")
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("origin/main lacks", err)

    def test_refuses_pr_that_is_not_open(self) -> None:
        self.set_pr(state="MERGED")
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("not OPEN", err)

    def test_refuses_pr_not_targeting_main(self) -> None:
        self.set_pr(baseRefName="develop")
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("not main", err)

    def test_refuses_when_origin_main_moves_during_the_gate(self) -> None:
        mover = self.tmp_path / "move_main.sh"
        mover.write_text(
            f"#!/bin/sh\ncd {self.repo.other} && git commit -q --allow-empty -m moved "
            "&& git push -q origin main\n"
        )
        os.environ[merge.GATE_CMD_ENV] = f"sh {mover}"
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("origin/main moved", err)
        self.assertIn("rerun make merge", err)
        self.assertFalse(self.merge_log.exists())

    def test_refuses_when_pr_head_moves_during_the_gate(self) -> None:
        mover = self.tmp_path / "move_head.sh"
        mover.write_text(
            f"#!/bin/sh\ncd {self.repo.other} && git fetch -q origin "
            "&& git switch -q -c feat/x origin/feat/x "
            "&& git commit -q --allow-empty -m moved && git push -q origin feat/x\n"
        )
        os.environ[merge.GATE_CMD_ENV] = f"sh {mover}"
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("PR head moved", err)
        self.assertFalse(self.merge_log.exists())

    def test_gate_failure_refuses_and_removes_temp_worktree(self) -> None:
        os.environ[merge.GATE_CMD_ENV] = "false"
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("gate failed (exit 1)", err)
        worktrees = self.repo.git("worktree", "list", "--porcelain").stdout
        self.assertNotIn("autopilot-merge-", worktrees)

    def test_conflict_lists_conflicting_files(self) -> None:
        self.repo.git("switch", "-q", "feat/x")
        self.head_sha = self.repo.commit_file("README.md", "# feature\n", "feature readme")
        self.repo.git("push", "-q", "origin", "feat/x")
        self.repo.git("switch", "-q", "main")
        self.set_pr()
        self.repo.git("switch", "-q", "main", cwd=self.repo.other)
        self.repo.commit_file("README.md", "# upstream\n", "upstream readme", cwd=self.repo.other)
        self.repo.git("push", "-q", "origin", "main", cwd=self.repo.other)
        code, _, err = self.run_merge()
        self.assertEqual(code, 1)
        self.assertIn("conflicts", err)
        self.assertIn("README.md", err)

    def test_server_refusal_of_changed_head_is_not_reported_as_merged(self) -> None:
        """The head can move after our fetch; report the server's conditional refusal."""
        original = merge_gate.run
        head_sha = self.head_sha

        def server(
            args: list[str], cwd: Path, check: bool = True
        ) -> subprocess.CompletedProcess[str]:
            if args[:3] == ["gh", "pr", "merge"]:
                assert args[-2:] == ["--match-head-commit", head_sha]
                return subprocess.CompletedProcess(args, 1, "", "head changed")
            return original(args, cwd, check)

        self.patch_attr(merge_gate, "run", server)
        code, out, err = self.run_merge("--keep")
        self.assertEqual(code, 1)
        self.assertIn("head changed", err)
        self.assertNotIn("PR #7 merged", out)

    def test_main_rejects_non_repo_root(self) -> None:
        code, _, err = self.capture(merge.main, ["--pr", "1", "--root", str(self.tmp_path)])
        self.assertEqual(code, 2)
        self.assertIn("refused (closed)", err)


class MergeFlowTest(MergeTestCase):
    """The happy path: gate, verify, merge commit, cleanup."""

    def test_base_is_resolved_after_the_lock_is_acquired(self) -> None:
        """A merge that landed while this run queued is gated against, not refused."""
        moved = []
        repo = self.repo

        @contextmanager
        def lock_then_move_main() -> Iterator[None]:
            repo.git("commit", "-q", "--allow-empty", "-m", "moved", cwd=repo.other)
            repo.git("push", "-q", "origin", "main", cwd=repo.other)
            moved.append(True)
            yield

        self.patch_attr(merge, "gate_lock", lock_then_move_main)
        code, _, err = self.run_merge("--keep")
        self.assertEqual(code, 0, err)
        self.assertTrue(moved)
        self.assertTrue(self.merge_log.exists())

    def test_stale_gh_head_uses_fetched_branch_tip(self) -> None:
        """gh lags behind a push: the stale head conflicts, the real tip resolves it."""
        self.repo.git("switch", "-q", "feat/x")
        stale_sha = self.repo.commit_file("README.md", "# feature\n", "feature readme")
        self.repo.git("push", "-q", "origin", "feat/x")
        self.repo.git("switch", "-q", "main", cwd=self.repo.other)
        self.repo.commit_file("README.md", "# upstream\n", "upstream readme", cwd=self.repo.other)
        self.repo.git("push", "-q", "origin", "main", cwd=self.repo.other)
        self.repo.git("fetch", "-q", "origin")
        self.repo.git("merge", "-q", "--no-edit", "origin/main", check=False)
        tip_sha = self.repo.commit_file("README.md", "# resolved\n", "resolve readme")
        self.repo.git("push", "-q", "origin", "feat/x")
        self.repo.git("switch", "-q", "main")
        self.set_pr(headRefOid=stale_sha)
        code, out, err = self.run_merge("--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn(
            f"merge: gh reports {stale_sha}, origin/feat/x is at {tip_sha}; using origin", out
        )
        self.assertIn(f"feat/x@{tip_sha[:10]}", out)

    def test_branch_absent_from_origin_falls_back_to_gh_head(self) -> None:
        self.set_pr(headRefName="feat/unpushed")
        code, out, err = self.run_merge("--dry-run")
        self.assertEqual(code, 0, err)
        self.assertNotIn("using origin", out)

    def test_mergeable_unknown_is_not_a_refusal(self) -> None:
        self.set_pr(mergeable="UNKNOWN")
        code, _, err = self.run_merge("--dry-run")
        self.assertEqual(code, 0, err)

    def test_dry_run_stops_before_gh_pr_merge(self) -> None:
        code, out, err = self.run_merge("--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn("dry run", out)
        self.assertFalse(self.merge_log.exists())

    def test_merges_via_gh_with_merge_commit_subject(self) -> None:
        code, _, err = self.run_merge("--keep")
        self.assertEqual(code, 0, err)
        logged = self.merge_log.read_text().strip()
        self.assertTrue(
            logged.startswith("pr merge 7 --merge --subject Merge pull request #7 from "), logged
        )
        self.assertIn(f"/feat/x --match-head-commit {self.head_sha}", logged)

    def test_gate_lock_covers_verification_and_merge(self) -> None:
        """A competing local gate cannot take the lock before the merge finishes."""
        for stage in ("run_preview_gate", "verify_parents_unchanged", "merge_via_gh"):
            with self.subTest(stage=stage):
                original = getattr(merge, stage)
                checked = []

                def guarded(*args: object, _original: object = original) -> object:
                    with gate_lock_module.lock_path().open("a") as handle:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    checked.append(True)
                    return _original(*args)

                with mock.patch.object(merge, stage, guarded):
                    code, _, err = self.run_merge("--keep")
                self.assertEqual(code, 0, err)
                self.assertTrue(checked)

    def test_success_from_merged_worktree_removes_it_and_prints_cd(self) -> None:
        worktree = self.tmp_path / "wt-feat-x"
        self.repo.git("worktree", "add", "-q", str(worktree), "feat/x")
        code, out, err = self.run_merge(root=worktree)
        self.assertEqual(code, 0, err)
        self.assertEqual(out.strip().splitlines()[-1], f"cd {self.repo.clone}")
        self.assertFalse(worktree.exists())
        branch_check = self.repo.git(
            "show-ref", "--verify", "--quiet", "refs/heads/feat/x", check=False
        )
        self.assertNotEqual(branch_check.returncode, 0)

    def test_success_with_keep_leaves_branch_in_place(self) -> None:
        worktree = self.tmp_path / "wt-keep"
        self.repo.git("worktree", "add", "-q", str(worktree), "feat/x")
        code, _, err = self.run_merge("--keep", root=worktree)
        self.assertEqual(code, 0, err)
        self.assertTrue(worktree.exists())

    def test_docs_only_pr_skips_heavy_stages(self) -> None:
        self.repo.git("switch", "-q", "-c", "docs/only", "origin/main")
        self.head_sha = self.repo.commit_file("CLAUDE.md", "notes\n", "docs")
        self.repo.git("push", "-q", "-u", "origin", "docs/only")
        self.repo.git("switch", "-q", "main")
        self.set_pr(headRefName="docs/only")
        code, out, err = self.run_merge("--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn("docs-only PR; skipping test-tooling and check", out)


class MergeHelpersTest(unittest.TestCase):
    """Pure helpers: the docs-only rule, the owner parser, the gate command list."""

    def test_is_docs_only(self) -> None:
        cases = [
            (["README.md"], True),
            (["CLAUDE.md", "docs/guide.md"], True),
            (["docs/sub/deep.md"], True),
            (["prompts/implement.md"], False),
            (["reviewers/general.md"], False),
            (["examples/tasks.example.md"], False),
            (["tasks.md"], False),
            (["docs/diagram.png"], False),
            (["README.md", "scripts/x.py"], False),
            ([], False),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertIs(merge_gate.is_docs_only(paths), expected)

    def test_default_gate_commands_run_gate_sh_only(self) -> None:
        tree = Path("/preview")
        self.assertEqual(
            merge.default_gate_commands(tree, docs_only=False),
            [["bash", "/preview/scripts/gate.sh"]],
        )
        self.assertEqual(
            merge.default_gate_commands(tree, docs_only=True),
            [["bash", "/preview/scripts/gate.sh", "--docs-only"]],
        )


class RepoOwnerTest(GitRepoTestCase):
    """repo_owner reads the owner segment of origin's URL."""

    def test_repo_owner_from_origin_url(self) -> None:
        cases = [
            ("https://github.com/diziet/autopilot.git", "diziet"),
            ("git@github.com:diziet/autopilot.git", "diziet"),
            ("/tmp/origin.git", "tmp"),
        ]
        for url, owner in cases:
            with self.subTest(url=url):
                self.repo.git("remote", "set-url", "origin", url)
                self.assertEqual(merge_gate.repo_owner(self.repo.clone), owner)


if __name__ == "__main__":
    unittest.main()
