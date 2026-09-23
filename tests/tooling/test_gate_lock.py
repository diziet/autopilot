"""scripts/gate_lock.py: exit-code pass-through, queueing, nesting, fail-closed."""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

from gitfixture import HELD_ENV, LOCK_ENV, SCRIPTS_DIR, TempDirTestCase

GATE_LOCK = str(SCRIPTS_DIR / "gate_lock.py")
HOLD_UNTIL_STDIN = "import sys; print('held', flush=True); sys.stdin.readline()"


def _env(lock: Path) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if key != HELD_ENV}
    env[LOCK_ENV] = str(lock)
    return env


def _start_holder(env: dict[str, str]) -> subprocess.Popen[str]:
    """Start a process that holds the lock and return once it really holds it.

    The wrapped command runs only after gate_lock.py acquired the flock, so its 'held' line is
    the handshake. Without it, a waiter started at the same time can take the lock first.
    """
    holder = subprocess.Popen(
        [sys.executable, GATE_LOCK, "--", sys.executable, "-c", HOLD_UNTIL_STDIN],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert holder.stdout is not None
    if holder.stdout.readline().strip() != "held":
        holder.kill()
        raise AssertionError("lock holder did not report 'held'")
    return holder


def _release(holder: subprocess.Popen[str]) -> int:
    """Let the holder's wrapped command exit and return the holder's exit code."""
    assert holder.stdin is not None
    holder.stdin.write("\n")
    holder.stdin.close()
    return holder.wait()


class GateLockTest(TempDirTestCase):
    """The lock serializes gates and never changes the wrapped command's result."""

    def test_wrapped_exit_code_passes_through(self) -> None:
        result = subprocess.run(
            [sys.executable, GATE_LOCK, "--", sys.executable, "-c", "import sys; sys.exit(7)"],
            env=_env(self.tmp_path / "lock"),
            check=False,
        )
        self.assertEqual(result.returncode, 7)

    def test_second_process_waits_until_first_releases(self) -> None:
        env = _env(self.tmp_path / "lock")
        holder = _start_holder(env)
        waiter = subprocess.Popen(
            [sys.executable, GATE_LOCK, "--", sys.executable, "-c", "print('ran')"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert waiter.stderr is not None
        waiting_line = waiter.stderr.readline()
        self.assertTrue(
            waiting_line.startswith(f"waiting for gate lock held by {holder.pid}"),
            waiting_line,
        )
        self.assertIsNone(waiter.poll())
        self.assertEqual(_release(holder), 0)
        stdout, _ = waiter.communicate()
        self.assertEqual(waiter.returncode, 0)
        self.assertEqual(stdout.strip(), "ran")

    def test_nested_invocation_runs_without_waiting(self) -> None:
        env = _env(self.tmp_path / "lock")
        holder = _start_holder(env)
        nested = subprocess.run(
            [sys.executable, GATE_LOCK, "--", sys.executable, "-c", "print('nested')"],
            env={**env, HELD_ENV: str(holder.pid)},
            capture_output=True,
            text=True,
            check=False,
        )
        _release(holder)
        self.assertEqual(nested.returncode, 0)
        self.assertEqual(nested.stdout.strip(), "nested")
        self.assertNotIn("waiting", nested.stderr)

    def test_fails_closed_when_lock_file_cannot_be_opened(self) -> None:
        marker = self.tmp_path / "ran.marker"
        result = subprocess.run(
            [
                sys.executable,
                GATE_LOCK,
                "--",
                sys.executable,
                "-c",
                f"open({str(marker)!r}, 'w')",
            ],
            env=_env(self.tmp_path / "missing-dir" / "lock"),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 97)
        self.assertIn("failed closed", result.stderr)
        self.assertFalse(marker.exists())

    def test_usage_error_without_command(self) -> None:
        for argv in ([], ["--"]):
            with self.subTest(argv=argv):
                result = subprocess.run(
                    [sys.executable, GATE_LOCK, *argv],
                    env=_env(self.tmp_path / "lock"),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
