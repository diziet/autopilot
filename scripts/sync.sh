#!/usr/bin/env bash
# Fetch and fast-forward the current worktree's branch. Refuses (fails CLOSED) when local main
# holds commits origin/main does not: that main must be repaired, not synced over.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$ROOT/Makefile" ] || { echo "sync: $ROOT is not the repo root" >&2; exit 2; }
cd "$ROOT"

git fetch -q origin
if git show-ref --verify --quiet refs/heads/main; then
  ahead="$(git rev-list --count origin/main..main)"
  if [ "$ahead" != "0" ]; then
    echo "sync: refused (closed): local main has $ahead commit(s) origin/main lacks." >&2
    echo "  Inspect: git log origin/main..main" >&2
    echo "  Repair:  git update-ref refs/heads/main origin/main   (refs are shared by every worktree)" >&2
    exit 1
  fi
fi

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || { echo "sync: detached HEAD; nothing to fast-forward" >&2; exit 1; }
if ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  echo "sync: origin/$branch does not exist; nothing to fast-forward"
  exit 0
fi
git merge --ff-only "origin/$branch"
echo "sync: $branch is at $(git rev-parse --short HEAD)"
