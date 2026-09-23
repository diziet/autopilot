"""Machine-wide gate lock: run a command while holding an exclusive flock.

Concurrent worktrees queue on one lock file instead of competing for cores.
Fails CLOSED: if the lock file cannot be opened or locked, the wrapped command
never runs and the exit code is non-zero. The wrapped command's real exit code
is passed through unchanged. A nested invocation inside a process that already
holds the lock (marked by AUTOPILOT_REPO_GATE_LOCK_HELD) runs the command directly.
"""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

LOCK_ENV = "AUTOPILOT_REPO_GATE_LOCK"
HELD_ENV = "AUTOPILOT_REPO_GATE_LOCK_HELD"
LOCK_NAME = "autopilot-gate.lock"
EXIT_LOCK_FAILED = 97


def lock_path() -> Path:
    """Return the lock file path: $AUTOPILOT_REPO_GATE_LOCK, else $TMPDIR/<LOCK_NAME>."""
    override = os.environ.get(LOCK_ENV)
    if override:
        return Path(override)
    return Path(os.environ.get("TMPDIR", "/tmp")) / LOCK_NAME


def _read_holder(handle: int) -> str:
    """Return the pid recorded in the lock file, or '?' when unreadable."""
    try:
        os.lseek(handle, 0, os.SEEK_SET)
        return os.read(handle, 64).decode(errors="replace").strip() or "?"
    except OSError:
        return "?"


@contextmanager
def gate_lock() -> Iterator[None]:
    """Hold the gate lock for the block; print a waiting line while queued."""
    if os.environ.get(HELD_ENV):
        yield
        return
    path = lock_path()
    handle = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(
                f"waiting for gate lock held by {_read_holder(handle)} ({path})",
                file=sys.stderr,
                flush=True,
            )
            fcntl.flock(handle, fcntl.LOCK_EX)
        os.ftruncate(handle, 0)
        os.pwrite(handle, str(os.getpid()).encode(), 0)
        os.environ[HELD_ENV] = str(os.getpid())
        try:
            yield
        finally:
            os.environ.pop(HELD_ENV, None)
            fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        os.close(handle)


def run_locked(command: list[str]) -> int:
    """Run `command` under the gate lock and return its exit code."""
    with gate_lock():
        return subprocess.call(command)


def main(argv: list[str]) -> int:
    """CLI: gate_lock.py [--] <command> [args...]."""
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("usage: gate_lock.py [--] <command> [args...]", file=sys.stderr)
        return 2
    try:
        return run_locked(argv)
    except OSError as error:
        print(f"gate lock failed closed: {error} ({lock_path()})", file=sys.stderr)
        return EXIT_LOCK_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
