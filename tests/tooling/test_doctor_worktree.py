"""scripts/doctor.sh and scripts/worktree.sh, run inside a fixture clone."""

from __future__ import annotations

import subprocess
import unittest

from gitfixture import GitRepoTestCase


class DoctorTest(GitRepoTestCase):
    """doctor fails closed and names each missing tool; it never installs anything."""

    def _doctor(self, dev_tools: str | None) -> subprocess.CompletedProcess[str]:
        env = dict(self.repo.env)
        env.pop("DEV_TOOLS", None)
        if dev_tools is not None:
            env["DEV_TOOLS"] = dev_tools
        return subprocess.run(
            ["bash", str(self.repo.clone / "scripts" / "doctor.sh")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_doctor_is_healthy_when_tools_and_hooks_are_present(self) -> None:
        result = self._doctor("git:git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("doctor: ✓ git at ", result.stdout)
        self.assertIn("doctor: healthy", result.stdout)

    def test_doctor_names_a_missing_tool_and_its_fix(self) -> None:
        result = self._doctor("git:git no-such-tool-xyz:xyz-formula")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no-such-tool-xyz not found on PATH", result.stderr)
        self.assertIn("brew install xyz-formula", result.stderr)

    def test_doctor_fails_when_hooks_are_not_installed(self) -> None:
        self.repo.git("config", "--unset", "core.hooksPath")
        result = self._doctor("git:git")
        self.assertEqual(result.returncode, 1)
        self.assertIn("core.hooksPath is 'unset'", result.stderr)
        self.assertIn("make hooks-install", result.stderr)

    def test_doctor_refuses_without_a_tool_list(self) -> None:
        result = self._doctor(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEV_TOOLS", result.stderr)


class WorktreeTest(GitRepoTestCase):
    """make worktree creates <outer>/<type>/<name> from origin/main and refuses bad names."""

    def _worktree(self, branch: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(self.repo.clone / "scripts" / "worktree.sh"), branch],
            env=self.repo.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_worktree_creates_sibling_tree_from_origin_main(self) -> None:
        upstream_sha = self.repo.push_from_other("main", "upstream")
        result = self._worktree("feat/new")
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.tmp_path / "feat" / "new"
        self.assertEqual(self.repo.head(cwd=target), upstream_sha)
        self.assertEqual(
            self.repo.git("symbolic-ref", "--short", "HEAD", cwd=target).stdout.strip(),
            "feat/new",
        )
        self.assertEqual(result.stdout.strip().splitlines()[-1], f"cd {target}")

    def test_worktree_refuses_invalid_names(self) -> None:
        for branch in ("", "main", "origin/main", "no-type-prefix"):
            with self.subTest(branch=branch):
                self.assertEqual(self._worktree(branch).returncode, 2)

    def test_worktree_refuses_an_existing_branch(self) -> None:
        self.repo.git("branch", "feat/taken")
        result = self._worktree("feat/taken")
        self.assertEqual(result.returncode, 1)
        self.assertIn("already exists", result.stderr)


if __name__ == "__main__":
    unittest.main()
