"""Report-only triage of local branches; `--delete` removes only the safe class.

Classes: checked-out (in a worktree; never deleted), open-pr (an open PR exists),
merged (contained in origin/main; the only deletable class), superseded (upstream
gone but not merged; needs a human), active (everything else).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CLASSES = ("checked-out", "open-pr", "merged", "superseded", "active")


@dataclass(frozen=True)
class Branch:
    """Facts about one local branch that decide its class."""

    name: str
    is_merged: bool
    upstream_gone: bool
    worktree: str | None
    has_open_pr: bool


def classify(branches: list[Branch]) -> dict[str, list[Branch]]:
    """Put each branch (main excluded) into exactly one class."""
    groups: dict[str, list[Branch]] = {name: [] for name in CLASSES}
    for branch in branches:
        if branch.name == "main":
            continue
        if branch.worktree:
            groups["checked-out"].append(branch)
        elif branch.has_open_pr:
            groups["open-pr"].append(branch)
        elif branch.is_merged:
            groups["merged"].append(branch)
        elif branch.upstream_gone:
            groups["superseded"].append(branch)
        else:
            groups["active"].append(branch)
    return groups


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True
    ).stdout


def worktree_branches(repo: Path) -> dict[str, str]:
    """Map branch name -> worktree path from `git worktree list --porcelain`."""
    mapping: dict[str, str] = {}
    path = ""
    for line in _git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = line.removeprefix("worktree ")
        elif line.startswith("branch refs/heads/"):
            mapping[line.removeprefix("branch refs/heads/")] = path
    return mapping


def open_pr_branches(repo: Path) -> set[str] | None:
    """Head branches of open PRs, or None when gh is unavailable."""
    try:
        result = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "200",
                "--json",
                "headRefName",
            ],
            cwd=repo,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None
    if result.returncode:
        return None
    return {str(item["headRefName"]) for item in json.loads(result.stdout)}


def gather(repo: Path) -> list[Branch]:
    """Collect every local branch with the facts classify() needs."""
    merged = set(
        _git(
            repo, "branch", "--merged", "origin/main", "--format=%(refname:short)"
        ).split()
    )
    worktrees = worktree_branches(repo)
    open_prs = open_pr_branches(repo)
    if open_prs is None:
        print(
            "branches-gc: gh unavailable; open PRs unknown; unmerged stay active",
            file=sys.stderr,
        )
        open_prs = set()
    branches: list[Branch] = []
    fmt = "%(refname:short)\t%(upstream:track,nobracket)"
    for line in _git(
        repo, "for-each-ref", "refs/heads", f"--format={fmt}"
    ).splitlines():
        name, _, track = line.partition("\t")
        branches.append(
            Branch(
                name=name,
                is_merged=name in merged,
                upstream_gone=track.strip() == "gone",
                worktree=worktrees.get(name),
                has_open_pr=name in open_prs,
            )
        )
    return branches


def report(groups: dict[str, list[Branch]]) -> None:
    """Print one section per class."""
    for name in CLASSES:
        print(f"{name} ({len(groups[name])}):")
        for branch in groups[name]:
            suffix = f"  [{branch.worktree}]" if branch.worktree else ""
            print(f"  {branch.name}{suffix}")


def delete_safe(repo: Path, groups: dict[str, list[Branch]]) -> int:
    """Delete the merged class with `git branch -d`; return the count removed."""
    count = 0
    for branch in groups["merged"]:
        subprocess.run(["git", "branch", "-d", branch.name], cwd=repo, check=True)
        count += 1
    subprocess.run(["git", "worktree", "prune"], cwd=repo, check=True)
    return count


def main(argv: list[str] | None = None) -> int:
    """CLI: report; with --delete also remove the merged class."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--delete", action="store_true", help="delete the merged (provably safe) class"
    )
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    repo: Path = options.root.resolve()
    if not (repo / ".git").exists():
        print(f"branches-gc: {repo} is not a git checkout", file=sys.stderr)
        return 2
    groups = classify(gather(repo))
    report(groups)
    if options.delete:
        print(f"branches-gc: deleted {delete_safe(repo, groups)} merged branch(es)")
    else:
        print(
            "branches-gc: report only; `make branches-gc args=--delete` deletes merged"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
