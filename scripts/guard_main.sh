#!/usr/bin/env bash
# Read-only local main: the guard functions behind the .githooks/ wrappers.
#
# Local `main` is a mirror of origin/main. Work happens in sibling worktrees (`make worktree`),
# is merged through `make merge pr=N`, and main only moves by fast-forwarding to origin/main.
# Sourced by the hooks; every function exits non-zero with a message when it refuses.
# All guards fail CLOSED on a refusal and OPEN only when git itself cannot answer.

guard_main_commit() {
  local branch
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$branch" = "main" ]; then
    echo "blocked: local main is a read-only mirror of origin/main; no commits on main." >&2
    echo "  Start work in a sibling worktree:  make worktree b=feat/<name>" >&2
    echo "  Land it with a gated PR:           make merge pr=<N>" >&2
    exit 1
  fi
}

# pre-push stdin: <local ref> <local sha> <remote ref> <remote sha> per line.
guard_main_push() {
  local _local_ref _local_sha remote_ref _remote_sha
  while read -r _local_ref _local_sha remote_ref _remote_sha; do
    if [ "$remote_ref" = "refs/heads/main" ]; then
      echo "blocked: refs/heads/main is only moved by the merge gate (make merge pr=<N>)." >&2
      echo "  Push a branch and open a PR instead:  git push -u origin HEAD && gh pr create" >&2
      exit 1
    fi
  done
}

# reference-transaction: $1 is prepared|committed|aborted; stdin has <old> <new> <ref> lines.
# Refusing in the `prepared` phase is what aborts the transaction (a `committed` refusal is too
# late: the ref has already moved). refs/heads/main may only move to a commit origin/main
# contains; origin/main updated in the same transaction (git fetch origin main:main) counts.
guard_main_ff() {
  local state="$1" old new ref main_old="" main_new="" remote_new=""
  [ "$state" = "prepared" ] || return 0
  while read -r old new ref; do
    case "$ref" in
      refs/heads/main) main_old="$old"; main_new="$new" ;;
      refs/remotes/origin/main) remote_new="$new" ;;
    esac
  done
  [ -n "$main_new" ] || return 0
  case "$main_new" in *[!0]*) ;; *) return 0 ;; esac   # all-zero = deletion; allow
  [ "$main_old" = "$main_new" ] && return 0
  if [ -z "$remote_new" ]; then
    remote_new="$(git rev-parse --quiet --verify refs/remotes/origin/main 2>/dev/null || true)"
    [ -n "$remote_new" ] || return 0                  # no origin/main yet: fail open
  fi
  if [ "$main_new" != "$remote_new" ] \
     && ! git merge-base --is-ancestor "$main_new" "$remote_new" 2>/dev/null; then
    echo "blocked: local main may only move to a commit origin/main already contains." >&2
    echo "  Sync with: make sync   (or git pull --ff-only origin main)" >&2
    echo "  Land work only via: make merge pr=<N>" >&2
    exit 1
  fi
}

# Regenerate <!-- fact:NAME --> values in tracked .md files (scripts/doc_facts.py --write),
# then stage each rewritten doc that had no unstaged edits before the rewrite. A doc with
# unstaged edits stays unstaged; `make doc-facts-check` reports it later. Advisory: never
# blocks the commit. Skips silently without scripts/doc_facts.py or a Python interpreter.
precommit_doc_facts() {
  local root python dirty output doc
  root="$(git rev-parse --show-toplevel)"
  [ -f "$root/scripts/doc_facts.py" ] || return 0
  python="$root/.venv/bin/python"
  [ -x "$python" ] || python="$(command -v python3 || true)"
  [ -n "$python" ] || return 0
  dirty="$(git -C "$root" -c core.quotePath=false diff --name-only)"
  if ! output="$("$python" "$root/scripts/doc_facts.py" --write 2>&1)"; then
    echo "pre-commit: doc facts not regenerated; run make doc-facts-check. Last lines:" >&2
    printf '%s\n' "$output" | tail -n 5 >&2
    return 0
  fi
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    case $'\n'"$dirty"$'\n' in
      *$'\n'"$doc"$'\n'*)
        echo "pre-commit: regenerated doc facts in $doc; not staged, it has unstaged edits" >&2
        ;;
      *)
        if git -C "$root" add -- "$doc"; then
          echo "pre-commit: regenerated and staged doc facts in $doc" >&2
        else
          echo "pre-commit: regenerated doc facts in $doc; git add failed" >&2
        fi
        ;;
    esac
  done <<< "$(printf '%s\n' "$output" | sed -n 's/^doc_facts: rewrote //p')"
}
