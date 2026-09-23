"""Shared fixtures for the repo-tooling tests: temp dirs and throwaway git repos.

The tooling tests use unittest from the standard library, so they run with the system python3
and need no virtualenv. `make test-tooling` runs them.
"""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "scripts"
HOOKS_DIR = REPO_ROOT / ".githooks"
NO_HOOKS = ("-c", "core.hooksPath=/dev/null")
LOCK_ENV = "AUTOPILOT_REPO_GATE_LOCK"
HELD_ENV = "AUTOPILOT_REPO_GATE_LOCK_HELD"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


@dataclass
class GitFixture:
    """A bare origin, a clone with the repo's hooks, and a hook-less second clone."""

    origin: Path
    clone: Path
    other: Path
    env: dict[str, str] = field(default_factory=dict)

    def git(
        self, *args: str, cwd: Path | None = None, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run git in the clone (or `cwd`) with the isolated environment."""
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.clone,
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
        )

    def head(self, ref: str = "HEAD", cwd: Path | None = None) -> str:
        """Resolve a ref to a sha."""
        return self.git("rev-parse", ref, cwd=cwd).stdout.strip()

    def commit_file(
        self, name: str, content: str, message: str, cwd: Path | None = None
    ) -> str:
        """Write, stage and commit a file; return the new sha."""
        cwd = cwd or self.clone
        (cwd / name).write_text(content)
        self.git("add", name, cwd=cwd)
        self.git("commit", "-q", "-m", message, cwd=cwd)
        return self.head(cwd=cwd)

    def push_from_other(self, branch: str, message: str) -> str:
        """Commit on `branch` in the hook-less clone and push it to origin."""
        self.git("fetch", "-q", "origin", cwd=self.other)
        if self.git(
            "show-ref",
            "--verify",
            "--quiet",
            f"refs/heads/{branch}",
            cwd=self.other,
            check=False,
        ).returncode:
            self.git("switch", "-q", "-c", branch, f"origin/{branch}", cwd=self.other)
        else:
            self.git("switch", "-q", branch, cwd=self.other)
            self.git("merge", "-q", "--ff-only", f"origin/{branch}", cwd=self.other)
        sha = self.commit_file(f"{message}.txt", message, message, cwd=self.other)
        self.git("push", "-q", "origin", branch, cwd=self.other)
        return sha


def isolated_git_env(tmp_path: Path) -> dict[str, str]:
    """Return os.environ without GIT_* and the held-lock marker, with a private git identity."""
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("GIT_") and key != HELD_ENV
    }
    env.update(
        {
            "GIT_CONFIG_GLOBAL": str(tmp_path / "gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "tooling-test",
            "GIT_AUTHOR_EMAIL": "tooling@example.invalid",
            "GIT_COMMITTER_NAME": "tooling-test",
            "GIT_COMMITTER_EMAIL": "tooling@example.invalid",
            LOCK_ENV: str(tmp_path / "gate.lock"),
        }
    )
    return env


FIXTURE_MAKEFILE = "gate-wiring-check:\n\t@true\n"


def install_tooling(clone: Path) -> None:
    """Copy the hooks, guard library and sync script into a fixture clone."""
    shutil.copytree(HOOKS_DIR, clone / ".githooks")
    (clone / "scripts").mkdir(exist_ok=True)
    for name in ("guard_main.sh", "sync.sh"):
        shutil.copy(SCRIPTS_DIR / name, clone / "scripts" / name)
    (clone / "Makefile").write_text(FIXTURE_MAKEFILE)


def make_git_repo(tmp_path: Path) -> GitFixture:
    """Create a bare origin, a clone with hooks on and main pushed, and a hook-less clone."""
    env = isolated_git_env(tmp_path)
    origin = tmp_path / "origin.git"
    clone = tmp_path / "clone"
    other = tmp_path / "other"
    fixture = GitFixture(origin=origin, clone=clone, other=other, env=env)
    subprocess.run(
        ["git", "init", "-q", "--bare", "-b", "main", str(origin)], env=env, check=True
    )
    subprocess.run(["git", "clone", "-q", str(origin), str(clone)], env=env, check=True)
    fixture.git("switch", "-q", "-c", "main", check=False)
    install_tooling(clone)
    (clone / "README.md").write_text("# fixture\n")
    fixture.git("add", "-A")
    fixture.git("commit", "-q", "-m", "init")
    fixture.git("push", "-q", "-u", "origin", "main")
    fixture.git("config", "core.hooksPath", ".githooks")
    subprocess.run(["git", "clone", "-q", str(origin), str(other)], env=env, check=True)
    return fixture


class TempDirTestCase(unittest.TestCase):
    """Give each test its own temp dir and restore os.environ after the test."""

    def setUp(self) -> None:
        """Create the temp dir and snapshot os.environ."""
        temp_dir = tempfile.TemporaryDirectory(prefix="autopilot-tooling-")
        self.addCleanup(temp_dir.cleanup)
        self.tmp_path = Path(temp_dir.name).resolve()
        env_patch = mock.patch.dict(os.environ)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        os.environ.pop(HELD_ENV, None)
        os.environ[LOCK_ENV] = str(self.tmp_path / "gate.lock")

    def prepend_path(self, directory: Path) -> None:
        """Put `directory` first on PATH for the rest of the test."""
        os.environ["PATH"] = f"{directory}{os.pathsep}{os.environ['PATH']}"

    def write_executable(self, path: Path, text: str) -> Path:
        """Write a script and make it executable."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)
        return path

    def capture(
        self, func: Callable[..., object], *args: object
    ) -> tuple[object, str, str]:
        """Call `func` and return its result with the stdout and stderr it printed."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            result = func(*args)
        return result, out.getvalue(), err.getvalue()


class GitRepoTestCase(TempDirTestCase):
    """TempDirTestCase plus a GitFixture in self.repo, with its env applied to os.environ."""

    def setUp(self) -> None:
        """Build the fixture repos and use their isolated git environment."""
        super().setUp()
        self.repo = make_git_repo(self.tmp_path)
        os.environ.clear()
        os.environ.update(self.repo.env)
