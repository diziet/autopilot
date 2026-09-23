"""Post-merge cleanup keeps work created while the gate is running."""

from __future__ import annotations

import unittest

import merge
from test_merge import MergeTestCase


class MergeCleanupTest(MergeTestCase):
    """A completed merge never discards later local work; cleanup fails open."""

    def test_cleanup_keeps_work_added_during_gate(self) -> None:
        for change in ("tracked", "untracked", "commit"):
            with self.subTest(change=change):
                worktree = self.tmp_path / f"working-{change}"
                self.repo.git("worktree", "add", "-q", str(worktree), "feat/x")
                name = "feature.sh" if change == "tracked" else "new-work.txt"

                def gate(*_args: object, _change: str = change, _tree: object = worktree) -> None:
                    if _change == "commit":
                        self.repo.commit_file(name, "keep me\n", "later work", cwd=_tree)
                    else:
                        (_tree / name).write_text("keep me\n")

                self.patch_attr(merge, "run_preview_gate", gate)
                code, out, err = self.run_merge(root=worktree)
                self.assertEqual(code, 0, err)
                self.assertEqual((worktree / name).read_text(), "keep me\n")
                self.assertEqual(self.repo.head("feat/x"), self.repo.head(cwd=worktree))
                self.assertIn("cleanup skipped (open)", out)
                self.repo.git("worktree", "remove", "--force", str(worktree))
                self.repo.git("switch", "-q", "feat/x")
                self.repo.git("reset", "-q", "--hard", self.head_sha)
                self.repo.git("switch", "-q", "main")

    def test_cleanup_refuses_a_locked_worktree(self) -> None:
        worktree = self.tmp_path / "locked"
        self.repo.git("worktree", "add", "-q", str(worktree), "feat/x")
        self.repo.git("worktree", "lock", str(worktree))
        code, out, err = self.run_merge(root=worktree)
        self.assertEqual(code, 0, err)
        self.assertTrue(worktree.exists())
        self.assertIn("cleanup skipped (open)", out)


if __name__ == "__main__":
    unittest.main()
