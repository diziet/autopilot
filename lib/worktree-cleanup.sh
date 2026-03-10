#!/usr/bin/env bash
# Worktree cleanup helpers for the Autopilot pipeline.
# Handles cleanup after merge, retry exhaustion, and stale worktree detection.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_WORKTREE_CLEANUP_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_WORKTREE_CLEANUP_LOADED=1

# Source dependencies.
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Remove the worktree directory for a task (does not delete the branch).
cleanup_task_worktree() {
  local project_dir="$1"
  local task_number="$2"

  if ! _use_worktrees; then
    return 0
  fi

  if ! _validate_worktree_task_num "$task_number"; then
    log_msg "$project_dir" "ERROR" \
      "cleanup_task_worktree: invalid task number: ${task_number}"
    return 1
  fi

  local worktree_path
  worktree_path="$(get_task_worktree_path "$project_dir" "$task_number")"

  if [[ ! -d "$worktree_path" ]]; then
    _prune_stale_worktree_metadata "$project_dir" "$worktree_path"
    return 0
  fi

  _remove_worktree_dir "$project_dir" "$task_number" "$worktree_path"
}

# Remove a worktree directory via git, falling back to manual rm.
_remove_worktree_dir() {
  local project_dir="$1"
  local task_number="$2"
  local worktree_path="$3"

  local wt_err
  if wt_err="$(git -C "$project_dir" worktree remove --force "$worktree_path" 2>&1)"; then
    log_msg "$project_dir" "INFO" \
      "Removed worktree for task ${task_number}"
    return 0
  fi

  log_msg "$project_dir" "WARNING" \
    "git worktree remove failed for task ${task_number}: ${wt_err} — cleaning up manually"
  if ! rm -rf "$worktree_path"; then
    log_msg "$project_dir" "ERROR" \
      "Manual rm -rf failed for worktree task ${task_number}: ${worktree_path}"
    return 1
  fi
  git -C "$project_dir" worktree prune 2>/dev/null || true
  log_msg "$project_dir" "INFO" \
    "Manually removed worktree for task ${task_number}"
}

# Prune stale worktree metadata when directory is already gone.
_prune_stale_worktree_metadata() {
  local project_dir="$1"
  local worktree_path="$2"

  if git -C "$project_dir" worktree list 2>/dev/null | grep -qF "$worktree_path"; then
    git -C "$project_dir" worktree prune 2>/dev/null || true
    log_msg "$project_dir" "DEBUG" \
      "Pruned stale worktree metadata for ${worktree_path}"
  fi
}

# Remove stale worktrees whose tasks are below current_task and branches are gone.
cleanup_stale_worktrees() {
  local project_dir="$1"

  if ! _use_worktrees; then
    return 0
  fi

  local worktrees_dir="${project_dir}/.autopilot/worktrees"
  [[ -d "$worktrees_dir" ]] || return 0

  local current_task
  current_task="$(read_state "$project_dir" "current_task")" || return 0
  [[ -n "$current_task" ]] || return 0

  local entry
  for entry in "$worktrees_dir"/task-*; do
    [[ -e "$entry" ]] || continue
    _maybe_cleanup_stale_entry "$project_dir" "$entry" "$current_task"
  done
}

# Check and clean up a single worktree entry if stale.
_maybe_cleanup_stale_entry() {
  local project_dir="$1"
  local entry="$2"
  local current_task="$3"

  local dir_name
  dir_name="${entry##*/}"

  # Extract task number from directory name (task-N).
  local task_num="${dir_name#task-}"
  if ! [[ "$task_num" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  # Only clean up tasks below the current task.
  if [[ "$task_num" -ge "$current_task" ]]; then
    return 0
  fi

  # Check if branch still exists (local or remote).
  if _task_branch_still_exists "$project_dir" "$task_num"; then
    log_msg "$project_dir" "DEBUG" \
      "Skipping worktree task-${task_num} — branch still exists"
    return 0
  fi

  # Branch gone and task is old — safe to remove.
  cleanup_task_worktree "$project_dir" "$task_num"
}

# Check if a task's branch exists locally or on the remote.
_task_branch_still_exists() {
  local project_dir="$1"
  local task_num="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_num")"

  if git -C "$project_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$project_dir" rev-parse --verify "origin/${branch_name}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
