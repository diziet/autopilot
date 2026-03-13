#!/usr/bin/env bash
# Rebase operations for Autopilot.
# Handles pre-merge conflict detection via gh pr view and auto-rebase
# of task branches onto the target branch after squash merges.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_REBASE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_REBASE_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# --- Mergeable Status Constants ---
readonly PR_MERGEABLE_CLEAN="CLEAN"
readonly PR_MERGEABLE_CONFLICTING="CONFLICTING"
readonly PR_MERGEABLE_UNKNOWN="UNKNOWN"
export PR_MERGEABLE_CLEAN PR_MERGEABLE_CONFLICTING PR_MERGEABLE_UNKNOWN

# --- Conflict Detection ---

# Check PR mergeable status via gh pr view.
check_pr_mergeable() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" \
      "Could not determine repo slug for mergeable check"
    echo "$PR_MERGEABLE_UNKNOWN"
    return 0
  }

  local pr_json
  if ! pr_json="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" \
    --json mergeable,mergeStateStatus 2>&1)"; then
    log_msg "$project_dir" "WARNING" \
      "Failed to check mergeable status for PR #${pr_number}: ${pr_json}"
    echo "$PR_MERGEABLE_UNKNOWN"
    return 0
  fi

  local mergeable merge_state
  mergeable="$(jq -r '.mergeable // empty' <<< "$pr_json")"
  merge_state="$(jq -r '.mergeStateStatus // empty' <<< "$pr_json")"

  if [[ "$mergeable" == "CONFLICTING" ]] || [[ "$merge_state" == "DIRTY" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} has conflicts (mergeable=${mergeable}, state=${merge_state})"
    echo "$PR_MERGEABLE_CONFLICTING"
    return 0
  fi

  if [[ "$merge_state" == "CLEAN" ]] || [[ "$mergeable" == "MERGEABLE" ]]; then
    echo "$PR_MERGEABLE_CLEAN"
    return 0
  fi

  echo "$PR_MERGEABLE_UNKNOWN"
}

# --- Auto-Rebase ---

# Rebase a task branch onto origin/target and force-push.
rebase_task_branch() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local target
  target="$(_resolve_checkout_target "$project_dir")"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Resolve effective working directory (worktree path or project_dir).
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  log_msg "$project_dir" "INFO" \
    "Attempting rebase of ${branch_name} onto origin/${target}"

  # Fetch latest target from remote.
  local fetch_stderr
  fetch_stderr="$(timeout "$timeout_gh" \
    git -C "$project_dir" fetch origin "$target" 2>&1 1>/dev/null)" || {
    log_msg "$project_dir" "ERROR" \
      "Failed to fetch origin/${target} for rebase: ${fetch_stderr}"
    return 1
  }

  # Ensure we are on the task branch (in worktree mode, already checked out).
  local checkout_stderr
  checkout_stderr="$(git -C "$task_dir" checkout "$branch_name" 2>&1 1>/dev/null)" || {
    log_msg "$project_dir" "ERROR" \
      "Failed to checkout ${branch_name} for rebase: ${checkout_stderr}"
    return 1
  }

  # Attempt rebase.
  local rebase_stderr
  if ! rebase_stderr="$(git -C "$task_dir" rebase "origin/${target}" 2>&1 1>/dev/null)"; then
    log_msg "$project_dir" "WARNING" \
      "Rebase failed for ${branch_name}: ${rebase_stderr}"
    git -C "$task_dir" rebase --abort 2>/dev/null || true
    return 1
  fi

  # Force-push the rebased branch.
  local push_stderr
  push_stderr="$(timeout "$timeout_gh" \
    git -C "$task_dir" push --force-with-lease origin \
    "$branch_name" 2>&1 1>/dev/null)" || {
    log_msg "$project_dir" "ERROR" \
      "Force push failed after rebase for ${branch_name}: ${push_stderr}"
    return 1
  }

  log_msg "$project_dir" "INFO" \
    "Rebased and force-pushed ${branch_name} onto origin/${target}"
}

# --- Pre-Merge Conflict Resolution ---

# Check for conflicts and attempt auto-rebase before merge.
resolve_pre_merge_conflicts() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="$3"

  local merge_status
  merge_status="$(check_pr_mergeable "$project_dir" "$pr_number")"

  if [[ "$merge_status" == "$PR_MERGEABLE_CLEAN" ]]; then
    return 0
  fi

  if [[ "$merge_status" == "$PR_MERGEABLE_CONFLICTING" ]]; then
    log_msg "$project_dir" "INFO" \
      "PR #${pr_number} has conflicts — attempting auto-rebase"

    if rebase_task_branch "$project_dir" "$task_number"; then
      log_msg "$project_dir" "INFO" \
        "Auto-rebase succeeded for task ${task_number}"
      return 0
    fi

    # Rebase failed — write hint for fixer.
    local hint="Auto-rebase of task ${task_number} branch failed."
    hint="${hint} The branch has conflicts with the target branch"
    hint="${hint} after a squash merge. Manual conflict resolution needed."
    write_diagnosis_hints "$project_dir" "$task_number" "$hint"
    return 1
  fi

  # UNKNOWN — proceed cautiously, let merger handle it.
  log_msg "$project_dir" "WARNING" \
    "Unknown mergeable status for PR #${pr_number} — proceeding"
  return 0
}
