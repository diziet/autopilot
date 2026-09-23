"""Read-only-main hooks: pre-commit, pre-merge-commit, pre-push, reference-transaction."""

from __future__ import annotations

import os
import unittest

from gitfixture import NO_HOOKS, REPO_ROOT, GitRepoTestCase


class PreCommitTest(GitRepoTestCase):
    """pre-commit refuses commits on main and nothing else."""

    def test_pre_commit_refuses_commit_on_main(self) -> None:
        (self.repo.clone / "new.txt").write_text("x\n")
        self.repo.git("add", "new.txt")
        result = self.repo.git("commit", "-q", "-m", "on main", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("make worktree", result.stderr)
        self.assertEqual(self.repo.head(), self.repo.head("origin/main"))

    def test_pre_commit_allows_commit_on_feature_branch(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/x")
        (self.repo.clone / "new.txt").write_text("x\n")
        self.repo.git("add", "new.txt")
        result = self.repo.git("commit", "-q", "-m", "on branch", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.strip(), "")

    def test_pre_commit_leaves_staged_content_unchanged(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/raw")
        (self.repo.clone / "raw.sh").write_text("x=1;  echo  $x\n")
        self.repo.git("add", "raw.sh")
        result = self.repo.git("commit", "-q", "-m", "raw", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        committed = self.repo.git("show", "HEAD:raw.sh").stdout
        self.assertEqual(committed, "x=1;  echo  $x\n")

    def test_pre_merge_commit_refuses_merge_into_main(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/m")
        self.repo.commit_file("m.txt", "m\n", "feature")
        self.repo.git("switch", "-q", "main")
        result = self.repo.git("merge", "--no-ff", "--no-edit", "feat/m", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("read-only mirror", result.stderr)
        self.assertEqual(self.repo.head("main"), self.repo.head("origin/main"))


class PrePushTest(GitRepoTestCase):
    """pre-push refuses pushes to refs/heads/main."""

    def test_pre_push_refuses_push_to_main(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/p")
        self.repo.commit_file("p.txt", "p\n", "feature")
        before = self.repo.head("main", cwd=self.repo.origin)
        result = self.repo.git("push", "origin", "HEAD:refs/heads/main", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refs/heads/main", result.stderr)
        self.assertEqual(self.repo.head("main", cwd=self.repo.origin), before)

    def test_pre_push_allows_feature_branch(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/ok")
        sha = self.repo.commit_file("ok.txt", "ok\n", "feature")
        result = self.repo.git("push", "-q", "-u", "origin", "feat/ok", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("feat/ok", cwd=self.repo.origin), sha)

    def test_pre_push_runs_wiring_check_when_the_script_exists(self) -> None:
        (self.repo.clone / "scripts" / "check_gate_wiring.py").write_text("")
        (self.repo.clone / "Makefile").write_text(
            "gate-wiring-check:\n\t@echo wiring-ran >&2; exit 3\n"
        )
        self.repo.git("switch", "-q", "-c", "feat/wired")
        self.repo.git("add", "-A")
        self.repo.git("commit", "-q", "-m", "wired")
        result = self.repo.git("push", "-q", "-u", "origin", "feat/wired", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wiring-ran", result.stderr)


class ReferenceTransactionTest(GitRepoTestCase):
    """reference-transaction lets main move only to commits origin/main contains."""

    def test_refuses_non_fast_forward_move_of_main(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/rt")
        feature_sha = self.repo.commit_file("rt.txt", "rt\n", "feature")
        main_before = self.repo.head("main")
        result = self.repo.git("update-ref", "refs/heads/main", feature_sha, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin/main already contains", result.stderr)
        self.assertEqual(self.repo.head("main"), main_before)

    def test_refuses_fast_forward_merge_of_feature_into_main(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/ff")
        self.repo.commit_file("ff.txt", "ff\n", "feature")
        self.repo.git("switch", "-q", "main")
        result = self.repo.git("merge", "--ff-only", "feat/ff", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.repo.head("main"), self.repo.head("origin/main"))

    def test_allows_fast_forward_from_origin(self) -> None:
        new_sha = self.repo.push_from_other("main", "upstream")
        self.repo.git("fetch", "-q", "origin")
        result = self.repo.git("merge", "--ff-only", "origin/main", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("main"), new_sha)

    def test_allows_pull_ff_only_like_autopilot(self) -> None:
        """autopilot runs `git pull --ff-only origin main` in a project's checkout."""
        new_sha = self.repo.push_from_other("main", "upstream-pull")
        result = self.repo.git("pull", "-q", "--ff-only", "origin", "main", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("main"), new_sha)

    def test_allows_fetch_into_main_from_branch(self) -> None:
        new_sha = self.repo.push_from_other("main", "upstream2")
        self.repo.git("switch", "-q", "-c", "feat/elsewhere")
        result = self.repo.git("fetch", "-q", "origin", "main:main", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("main"), new_sha)


class HookSetupTest(GitRepoTestCase):
    """The hooks skip silently on old branches, and NO_HOOKS bypasses them."""

    def test_hooks_skip_silently_when_guard_library_is_absent(self) -> None:
        self.repo.git("rm", "-q", "scripts/guard_main.sh")
        result = self.repo.git("commit", "-q", "-m", "old branch shape", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.strip(), "")

    def test_hookless_commit_on_main_is_possible_for_fixture_setup(self) -> None:
        """The NO_HOOKS override that other tests rely on bypasses the guard."""
        (self.repo.clone / "raw.txt").write_text("raw\n")
        self.repo.git("add", "raw.txt")
        result = self.repo.git(*NO_HOOKS, "commit", "-q", "-m", "bypass", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)


class HookFilesTest(unittest.TestCase):
    """The repo's hook files are executable, or git ignores them."""

    def test_hooks_are_executable_in_the_repo(self) -> None:
        for hook in ("pre-commit", "pre-merge-commit", "pre-push", "reference-transaction"):
            with self.subTest(hook=hook):
                self.assertTrue(os.access(REPO_ROOT / ".githooks" / hook, os.X_OK))


if __name__ == "__main__":
    unittest.main()
