#!/usr/bin/env bash
# Start work: make worktree b=<type>/<name>. Creates the sibling tree <outer>/<b> from the latest
# origin/main as a new branch (not tracking main), installs the hooks, then prints the `cd`.
# There is no dependency bootstrap: bash, bats, shellcheck and python3 come from the machine.
# Refuses when the branch or the directory already exists.
set -euo pipefail

branch="${1:-}"
[ -n "$branch" ] || { echo "usage: make worktree b=<type>/<name>   e.g. b=feat/my-change" >&2; exit 2; }
case "$branch" in
  main|*/main) echo "worktree: refusing to create a tree for '$branch'" >&2; exit 2 ;;
  */*) ;;
  *) echo "worktree: branch must be <type>/<name> (feat/, fix/, docs/, chore/, ...)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$ROOT/Makefile" ] || { echo "worktree: $ROOT is not the repo root" >&2; exit 2; }
cd "$ROOT"
primary="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
outer="$(dirname "$primary")"
target="$outer/$branch"

if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "worktree: branch '$branch' already exists; pick another name or: git worktree add $target $branch" >&2
  exit 1
fi
if [ -e "$target" ]; then
  echo "worktree: $target already exists" >&2
  exit 1
fi

git fetch -q origin main
git worktree add --no-track -b "$branch" "$target" origin/main
make -f "$ROOT/Makefile" -C "$target" -s hooks-install
echo "worktree: ready at $target"
echo "cd $target"
