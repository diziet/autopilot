"""scripts/merge_gate.preview_merge: the refusal message on a failed git merge."""

from __future__ import annotations

import subprocess
import unittest

import merge_gate
from gitfixture import NO_HOOKS, GitRepoTestCase

UNKNOWN_SHA = "0" * 40


class PreviewMergeTest(GitRepoTestCase):
    """A failed preview merge names the conflicting files or relays git's message."""

    def _conflicting_branch(self) -> tuple[str, str]:
        """Return (base_sha, head_sha) where both sides rewrite README.md."""
        self.repo.git("switch", "-q", "-c", "feat/c")
        head_sha = self.repo.commit_file("README.md", "# feature\n", "feature readme")
        self.repo.git("switch", "-q", "main")
        (self.repo.clone / "README.md").write_text("# upstream\n")
        self.repo.git("add", "README.md")
        self.repo.git(*NO_HOOKS, "commit", "-q", "-m", "upstream readme")
        return self.repo.head(), head_sha

    def _preview_refusal(self, base_sha: str, head_sha: str) -> str:
        with merge_gate.temp_worktree(self.repo.clone, base_sha) as tree:
            with self.assertRaises(merge_gate.MergeRefusalError) as refusal:
                merge_gate.preview_merge(tree, head_sha)
        return str(refusal.exception)

    def test_conflicting_preview_names_the_conflicting_file(self) -> None:
        base_sha, head_sha = self._conflicting_branch()
        message = self._preview_refusal(base_sha, head_sha)
        self.assertTrue(message.startswith("preview merge has conflicts in:"), message)
        self.assertIn("README.md", message)
        self.assertNotIn("merge failed", message)

    def test_non_conflict_failure_reports_git_message(self) -> None:
        message = self._preview_refusal(self.repo.head(), UNKNOWN_SHA)
        self.assertTrue(message.startswith("preview merge failed:"), message)
        self.assertIn("not something we can merge", message)
        self.assertNotIn("conflicts in", message)

    def test_failure_message_includes_stdout_and_stderr(self) -> None:
        result = subprocess.CompletedProcess(
            ["git", "merge"], 1, "CONFLICT (content): Merge conflict in x\n", "hook: no\n"
        )
        message = merge_gate.describe_failed_merge(self.repo.clone, result)
        self.assertIn("CONFLICT (content): Merge conflict in x", message)
        self.assertIn("hook: no", message)

    def test_failure_message_is_never_empty(self) -> None:
        result = subprocess.CompletedProcess(["git", "merge"], 128, "", "")
        message = merge_gate.describe_failed_merge(self.repo.clone, result)
        self.assertEqual(message, "preview merge failed: git merge exited 128 with no output")

    def test_temp_worktree_is_removed_on_exit(self) -> None:
        with merge_gate.temp_worktree(self.repo.clone, self.repo.head()) as tree:
            self.assertTrue((tree / "README.md").exists())
        self.assertFalse(tree.exists())
        self.assertNotIn(str(tree), self.repo.git("worktree", "list").stdout)


if __name__ == "__main__":
    unittest.main()
