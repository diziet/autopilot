"""Git and gh helpers for scripts/merge.py: refusals, PR lookup, preview worktree."""

from __future__ import annotations

import json
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

# The *.md files no test reads: a PR that changes only these skips test-tooling and check.
# Other *.md files run the full gate. The bats tests read prompts/, reviewers/ and examples/, and
# the daemon sends prompts/ and reviewers/ to models, copies examples/ and parses tasks.md.
DOCS_ONLY_FILES = frozenset({"README.md", "CLAUDE.md"})
DOCS_ONLY_DIR = "docs/"


class MergeRefusalError(Exception):
    """A guard refused the merge; the message says why. Always fails closed."""


@dataclass(frozen=True)
class PullRequest:
    """The fields of `gh pr view` the merge path reads."""

    number: int
    head_ref: str
    head_sha: str
    base_ref: str
    state: str
    mergeable: str


def run(
    args: list[str], cwd: Path, check: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a command capturing text output; raise on failure when `check`."""
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=check)


def git(cwd: Path, *args: str) -> str:
    """Run git in `cwd` and return stripped stdout."""
    return run(["git", *args], cwd).stdout.strip()


def refuse_dirty_tree(cwd: Path) -> None:
    """Refuse when the invoking tree has modified or untracked files."""
    status = git(cwd, "status", "--porcelain", "--untracked-files=all")
    if status:
        raise MergeRefusalError(
            f"invoking tree has uncommitted or untracked files:\n{status}"
        )


def refuse_divergent_main(cwd: Path) -> None:
    """Refuse when local main has commits that origin/main does not."""
    if run(
        ["git", "show-ref", "--verify", "--quiet", "refs/heads/main"], cwd, check=False
    ).returncode:
        return
    ahead = git(cwd, "rev-list", "--count", "origin/main..main")
    if ahead != "0":
        raise MergeRefusalError(
            f"local main has {ahead} commit(s) origin/main lacks; "
            "repair main first (make sync explains how)"
        )


def fetch_pull_request(number: int, cwd: Path) -> PullRequest:
    """Look the PR up with gh and require it to be OPEN against main."""
    result = run(
        [
            "gh",
            "pr",
            "view",
            str(number),
            "--json",
            "headRefName,headRefOid,baseRefName,state,mergeable",
        ],
        cwd,
        check=False,
    )
    if result.returncode:
        raise MergeRefusalError(f"gh pr view {number} failed: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    pr = PullRequest(
        number=number,
        head_ref=str(data["headRefName"]),
        head_sha=str(data["headRefOid"]),
        base_ref=str(data["baseRefName"]),
        state=str(data["state"]),
        mergeable=str(data.get("mergeable", "")),
    )
    if pr.state != "OPEN":
        raise MergeRefusalError(f"PR #{number} is {pr.state}, not OPEN")
    if pr.base_ref != "main":
        raise MergeRefusalError(f"PR #{number} targets {pr.base_ref}, not main")
    return pr


def remote_branch_sha(cwd: Path, branch: str) -> str | None:
    """SHA of origin/<branch> as of the last fetch, or None when origin lacks it."""
    result = run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"],
        cwd,
        check=False,
    )
    return result.stdout.strip() or None


def ensure_object(cwd: Path, sha: str, pr_number: int) -> None:
    """Fetch refs/pull/N/head when `sha` is absent; refuse the merge if it still is."""
    if (
        run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd, check=False).returncode
        == 0
    ):
        return
    run(
        ["git", "fetch", "-q", "origin", f"refs/pull/{pr_number}/head"],
        cwd,
        check=False,
    )
    if run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd, check=False).returncode:
        raise MergeRefusalError(
            f"PR head {sha} is not reachable from origin; push the branch and retry"
        )


@contextmanager
def temp_worktree(repo: Path, base_sha: str) -> Iterator[Path]:
    """Worktree at `base_sha` under $TMPDIR on a throwaway branch; both removed on exit.

    The tree is on a branch, not a detached HEAD. The bats tests run bin/autopilot-review,
    whose check_self_update runs `git symbolic-ref --short HEAD` on this checkout. On a
    detached HEAD that exits 128, and `set -euo pipefail` ends the script with that status.
    """
    tree = Path(tempfile.mkdtemp(prefix="autopilot-merge-"))
    branch = f"merge-preview/{tree.name}"
    try:
        git(repo, "worktree", "add", "-q", "-b", branch, str(tree), base_sha)
        yield tree
    finally:
        run(["git", "worktree", "remove", "--force", str(tree)], repo, check=False)
        run(["git", "worktree", "prune"], repo, check=False)
        # The branch holds only the preview merge commit, so -D loses nothing.
        run(["git", "branch", "-D", branch], repo, check=False)


def preview_merge(tree: Path, head_sha: str) -> None:
    """Run `git merge --no-ff head_sha` in the preview tree; on failure, refuse and say why."""
    result = run(["git", "merge", "--no-ff", "--no-edit", head_sha], tree, check=False)
    if result.returncode == 0:
        return
    raise MergeRefusalError(describe_failed_merge(tree, result))


def describe_failed_merge(tree: Path, result: subprocess.CompletedProcess[str]) -> str:
    """Name the unmerged paths in `tree`, else relay git's own message; never empty.

    git writes `CONFLICT (...)` lines to stdout and errors such as an unknown SHA
    to stderr, and a non-conflict failure leaves no unmerged paths at all.
    """
    conflicts = git(tree, "diff", "--name-only", "--diff-filter=U")
    if conflicts:
        return f"preview merge has conflicts in:\n{conflicts}"
    output = "\n".join(
        stream.strip() for stream in (result.stdout, result.stderr) if stream.strip()
    )
    if not output:
        output = f"git merge exited {result.returncode} with no output"
    return f"preview merge failed: {output}"


def changed_paths(repo: Path, base_sha: str, head_sha: str) -> list[str]:
    """Paths the PR changes relative to its merge base with `base_sha`."""
    output = git(repo, "diff", "--name-only", f"{base_sha}...{head_sha}")
    return [line for line in output.splitlines() if line]


def is_docs_only(paths: list[str]) -> bool:
    """True when every changed path is README.md, CLAUDE.md or a *.md under docs/."""
    if not paths:
        return False
    return all(
        p in DOCS_ONLY_FILES or (p.startswith(DOCS_ONLY_DIR) and p.endswith(".md"))
        for p in paths
    )


def merge_via_gh(pr: PullRequest, owner: str, cwd: Path) -> None:
    """The repo tooling's only `gh pr merge` call. lib/merger.sh has its own, for task PRs."""
    subject = f"Merge pull request #{pr.number} from {owner}/{pr.head_ref}"
    result = run(
        [
            "gh",
            "pr",
            "merge",
            str(pr.number),
            "--merge",
            "--subject",
            subject,
            "--match-head-commit",
            pr.head_sha,
        ],
        cwd,
        check=False,
    )
    if result.returncode:
        raise MergeRefusalError(f"gh pr merge failed: {result.stderr.strip()}")


def repo_owner(cwd: Path) -> str:
    """Owner segment of origin's URL (github.com/<owner>/<repo>)."""
    url = git(cwd, "remote", "get-url", "origin")
    tail = url.rstrip("/").removesuffix(".git")
    parts = tail.replace(":", "/").split("/")
    return parts[-2] if len(parts) >= 2 else "origin"
