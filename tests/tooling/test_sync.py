"""scripts/sync.sh: fast-forward the current branch; refuse a divergent local main."""

from __future__ import annotations

import subprocess
import unittest

from gitfixture import NO_HOOKS, GitRepoTestCase


class SyncTest(GitRepoTestCase):
    """make sync fast-forwards and refuses when local main has diverged."""

    def _sync(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "scripts/sync.sh"],
            cwd=self.repo.clone,
            env=self.repo.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_sync_refuses_when_local_main_diverges(self) -> None:
        (self.repo.clone / "stranded.txt").write_text("x\n")
        self.repo.git("add", "stranded.txt")
        self.repo.git(*NO_HOOKS, "commit", "-q", "-m", "stranded")
        result = self._sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn("refused (closed)", result.stderr)

    def test_sync_fast_forwards_main(self) -> None:
        new_sha = self.repo.push_from_other("main", "upstream")
        result = self._sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("main"), new_sha)

    def test_sync_fast_forwards_feature_branch(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/s")
        self.repo.commit_file("s.txt", "s\n", "feature")
        self.repo.git("push", "-q", "-u", "origin", "feat/s")
        new_sha = self.repo.push_from_other("feat/s", "more")
        result = self._sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.head("feat/s"), new_sha)

    def test_sync_without_remote_branch_is_a_no_op(self) -> None:
        self.repo.git("switch", "-q", "-c", "feat/local-only")
        result = self._sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to fast-forward", result.stdout)

    def test_sync_refuses_outside_the_repo_root(self) -> None:
        (self.repo.clone / "Makefile").unlink()
        result = self._sync()
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not the repo root", result.stderr)


if __name__ == "__main__":
    unittest.main()
