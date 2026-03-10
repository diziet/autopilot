#!/usr/bin/env bash
# Git branch, commit, and push operations for Autopilot.
# PR title/body extraction and creation are in git-pr.sh.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_GIT_OPS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_GIT_OPS_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"
# shellcheck source=lib/preflight.sh
source "${BASH_SOURCE[0]%/*}/preflight.sh"
# shellcheck source=lib/worktree-deps.sh
source "${BASH_SOURCE[0]%/*}/worktree-deps.sh"

# --- Repo Slug ---

# Derive OWNER/REPO slug from the git remote URL.
get_repo_slug() {
  local project_dir="${1:-.}"
  local url
  url="$(git -C "$project_dir" remote get-url origin 2>/dev/null)" || return 1

  # Strip .git suffix, then extract owner/repo from various URL forms.
  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# --- Branch Operations ---

# Detect the default branch name (main or master) for a repo.
# Uses symbolic-ref to find origin's HEAD, falls back to main.
detect_default_branch() {
  local project_dir="${1:-.}"

  # Try origin's HEAD symbolic ref first (works for cloned repos).
  local ref
  ref="$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || true
  if [[ -n "$ref" ]]; then
    echo "${ref##refs/remotes/origin/}"
    return 0
  fi

  # Fallback: check if main or master exists locally.
  if git -C "$project_dir" rev-parse --verify main >/dev/null 2>&1; then
    echo "main"
    return 0
  fi
  if git -C "$project_dir" rev-parse --verify master >/dev/null 2>&1; then
    echo "master"
    return 0
  fi

  # Last resort: default to main.
  echo "main"
}

# Validate that a task number is a positive integer.
_validate_worktree_task_num() {
  local task_number="$1"
  [[ "$task_number" =~ ^[0-9]+$ ]]
}

# Build the branch name for a given task number.
build_branch_name() {
  local task_number="$1"
  local prefix="${AUTOPILOT_BRANCH_PREFIX:-autopilot}"
  echo "${prefix}/task-${task_number}"
}

# Return the worktree path for a given task number.
get_task_worktree_path() {
  local project_dir="${1:-.}"
  local task_number="$2"
  if ! _validate_worktree_task_num "$task_number"; then
    log_msg "$project_dir" "ERROR" "Invalid task number: ${task_number}"
    return 1
  fi
  echo "${project_dir}/.autopilot/worktrees/task-${task_number}"
}

# Check if worktree mode is enabled.
_use_worktrees() {
  [[ "${AUTOPILOT_USE_WORKTREES:-true}" == "true" ]]
}

# Resolve the effective working directory for a task.
# In worktree mode, returns the worktree path. In direct mode, returns project_dir.
resolve_task_dir() {
  local project_dir="${1:-.}"
  local task_number="$2"
  if _use_worktrees; then
    get_task_worktree_path "$project_dir" "$task_number"
  else
    echo "$project_dir"
  fi
}

# Create and checkout a new branch for the given task.
# In worktree mode, creates a git worktree at .autopilot/worktrees/task-N/.
# In direct mode, checks out the branch in the project working tree.
create_task_branch() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  if _use_worktrees; then
    # Runtime symlink check — symlinks can be added after init.
    if ! check_worktree_compatibility "$project_dir" >/dev/null 2>&1; then
      log_msg "$project_dir" "WARNING" \
        "Escaping symlinks detected — falling back to direct checkout mode for task ${task_number}"
      _create_task_branch_direct "$project_dir" "$branch_name" "$target"
      return $?
    fi
    _create_task_branch_worktree "$project_dir" "$task_number" "$branch_name" "$target"
  else
    _create_task_branch_direct "$project_dir" "$branch_name" "$target"
  fi
}

# Symlink a file or directory into the worktree if it exists in source but not target.
_symlink_if_missing() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local project_dir="$4"

  if [[ -e "$src" ]] && [[ ! -e "$dst" ]]; then
    ln -s "$src" "$dst"
    log_msg "$project_dir" "DEBUG" \
      "Symlinked ${label} into worktree at ${dst%/*}"
  fi
}

# Symlink CLAUDE.md and .claude/ from main tree into a worktree.
# Only creates symlinks for items present in project_dir but missing from worktree.
_setup_worktree_symlinks() {
  local project_dir="$1"
  local worktree_path="$2"

  _symlink_if_missing \
    "${project_dir}/CLAUDE.md" "${worktree_path}/CLAUDE.md" "CLAUDE.md" "$project_dir"
  _symlink_if_missing \
    "${project_dir}/.claude" "${worktree_path}/.claude" ".claude/" "$project_dir"
}

# Create a task branch using git worktree.
_create_task_branch_worktree() {
  local project_dir="$1"
  local task_number="$2"
  local branch_name="$3"
  local target="$4"

  local worktree_path
  worktree_path="$(get_task_worktree_path "$project_dir" "$task_number")"

  mkdir -p "${worktree_path%/*}"

  local wt_err
  if ! wt_err="$(git -C "$project_dir" worktree add "$worktree_path" \
      -b "$branch_name" "$target" 2>&1)"; then
    log_msg "$project_dir" "ERROR" \
      "Failed to create worktree branch: ${branch_name}: ${wt_err}"
    return 1
  fi

  log_msg "$project_dir" "INFO" \
    "Created worktree branch: ${branch_name} from ${target} at ${worktree_path}"

  # Symlink untracked CLAUDE.md and .claude/ so Claude Code finds them.
  _setup_worktree_symlinks "$project_dir" "$worktree_path"

  # Install project dependencies in the worktree.
  if ! install_worktree_deps "$project_dir" "$worktree_path"; then
    log_msg "$project_dir" "ERROR" \
      "Dependency installation failed for worktree: ${worktree_path}"
    return 1
  fi
}

# Create a task branch using direct checkout (fallback mode).
_create_task_branch_direct() {
  local project_dir="$1"
  local branch_name="$2"
  local target="$3"

  if ! git -C "$project_dir" checkout -b "$branch_name" "$target" 2>/dev/null; then
    log_msg "$project_dir" "ERROR" "Failed to create branch: ${branch_name}"
    return 1
  fi

  log_msg "$project_dir" "INFO" "Created branch: ${branch_name} from ${target}"
}

# Delete a task branch locally and remotely.
# In worktree mode, removes the worktree first, then deletes the branch.
# In direct mode, switches away from the branch if checked out, then deletes.
delete_task_branch() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  if _use_worktrees; then
    _delete_task_branch_worktree "$project_dir" "$task_number" "$branch_name"
  else
    _delete_task_branch_direct "$project_dir" "$branch_name"
  fi
}

# Delete a branch locally and remotely (shared by worktree and direct modes).
_delete_branch_local_and_remote() {
  local project_dir="$1"
  local branch_name="$2"

  local deleted_local=false
  if git -C "$project_dir" branch -D "$branch_name" 2>/dev/null; then
    log_msg "$project_dir" "INFO" "Deleted local branch: ${branch_name}"
    deleted_local=true
  fi

  local deleted_remote=false
  if git -C "$project_dir" push origin --delete "$branch_name" 2>/dev/null; then
    deleted_remote=true
  fi

  if [[ "$deleted_local" == false && "$deleted_remote" == false ]]; then
    log_msg "$project_dir" "ERROR" \
      "Failed to delete branch ${branch_name} — local and remote deletion both failed"
    return 1
  fi
}

# Delete a task branch and its worktree.
_delete_task_branch_worktree() {
  local project_dir="$1"
  local task_number="$2"
  local branch_name="$3"

  local worktree_path
  worktree_path="$(get_task_worktree_path "$project_dir" "$task_number")"

  # Remove worktree if it exists. Use --force for dirty worktrees (coder crashes).
  if [[ -d "$worktree_path" ]]; then
    if ! git -C "$project_dir" worktree remove --force "$worktree_path" 2>/dev/null; then
      log_msg "$project_dir" "WARNING" \
        "git worktree remove failed for ${worktree_path} — cleaning up manually"
      rm -rf "$worktree_path"
    fi
  fi

  # Prune stale worktree metadata before branch deletion. Without this,
  # git refuses to delete a branch it thinks is still checked out in a worktree.
  git -C "$project_dir" worktree prune 2>/dev/null || true

  _delete_branch_local_and_remote "$project_dir" "$branch_name"
}

# Delete a task branch using direct checkout (fallback mode).
_delete_task_branch_direct() {
  local project_dir="$1"
  local branch_name="$2"

  # Cannot delete the currently checked-out branch — switch away first.
  local current_branch
  current_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
  if [[ "$current_branch" == "$branch_name" ]]; then
    local checkout_target
    checkout_target="$(_resolve_checkout_target "$project_dir")"
    # Force checkout: discard uncommitted changes — the branch is being deleted anyway.
    local checkout_err
    if ! checkout_err="$(git -C "$project_dir" checkout --force "$checkout_target" 2>&1)"; then
      log_msg "$project_dir" "ERROR" \
        "Cannot switch away from ${branch_name} — force checkout ${checkout_target} failed: ${checkout_err}"
      return 1
    fi
    # Remove untracked files that might cause issues on the fresh branch.
    git -C "$project_dir" clean -fd >/dev/null 2>&1 || true
  fi

  _delete_branch_local_and_remote "$project_dir" "$branch_name"
}

# Resolve which branch to checkout when switching away from a task branch.
# Uses AUTOPILOT_TARGET_BRANCH if set, otherwise detects the default branch.
_resolve_checkout_target() {
  local project_dir="${1:-.}"
  local target="${AUTOPILOT_TARGET_BRANCH:-}"

  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi

  detect_default_branch "$project_dir"
}

# Check if a task branch already exists (locally, remotely, or as worktree).
task_branch_exists() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # In worktree mode, check git's worktree list for a valid entry (not just dir).
  if _use_worktrees; then
    local worktree_path
    worktree_path="$(get_task_worktree_path "$project_dir" "$task_number")"
    if git -C "$project_dir" worktree list 2>/dev/null | grep -qF "$worktree_path"; then
      return 0
    fi
  fi

  # Check local branch, then remote.
  if git -C "$project_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$project_dir" rev-parse --verify "origin/${branch_name}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# --- Commit Operations ---

# Stage and commit all changes with the given message.
commit_changes() {
  local project_dir="${1:-.}"
  local message="$2"

  if [[ -z "$message" ]]; then
    log_msg "$project_dir" "ERROR" "Commit message must not be empty"
    return 1
  fi

  # Stage all changes (tracked and untracked).
  git -C "$project_dir" add -A 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to stage changes"
    return 1
  }

  # Check if there are staged changes to commit.
  if git -C "$project_dir" diff --cached --quiet 2>/dev/null; then
    log_msg "$project_dir" "WARNING" "No changes to commit"
    return 0
  fi

  git -C "$project_dir" commit -m "$message" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to commit: ${message}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Committed: ${message}"
}

# Push the current branch to origin.
push_branch() {
  local project_dir="${1:-.}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local branch_name
  branch_name="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [[ -z "$branch_name" ]]; then
    log_msg "$project_dir" "ERROR" "Could not determine current branch"
    return 1
  fi

  timeout "$timeout_gh" git -C "$project_dir" push -u origin "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to push branch: ${branch_name}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Pushed branch: ${branch_name}"
}

# Get the current HEAD SHA for the project.
get_head_sha() {
  local project_dir="${1:-.}"
  git -C "$project_dir" rev-parse HEAD 2>/dev/null
}
