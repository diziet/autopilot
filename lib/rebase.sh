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

  local pr_json
  pr_json="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --json mergeable,mergeStateStatus 2>/dev/null)" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to check mergeable status for PR #${pr_number}"
    echo "$PR_MERGEABLE_UNKNOWN"
    return 0
  }

  local mergeable merge_state
  mergeable="$(echo "$pr_json" | jq -r '.mergeable // empty')"
  merge_state="$(echo "$pr_json" | jq -r '.mergeStateStatus // empty')"

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
  local target="${AUTOPILOT_TARGET_BRANCH:-main}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  log_msg "$project_dir" "INFO" \
    "Attempting rebase of ${branch_name} onto origin/${target}"

  # Fetch latest target from remote.
  timeout "$timeout_gh" \
    git -C "$project_dir" fetch origin "$target" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to fetch origin/${target} for rebase"
    return 1
  }

  # Ensure we are on the task branch.
  git -C "$project_dir" checkout "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to checkout ${branch_name} for rebase"
    return 1
  }

  # Attempt rebase.
  if ! git -C "$project_dir" rebase "origin/${target}" 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Rebase failed for ${branch_name} — aborting"
    git -C "$project_dir" rebase --abort 2>/dev/null || true
    return 1
  fi

  # Force-push the rebased branch.
  timeout "$timeout_gh" \
    git -C "$project_dir" push --force-with-lease origin \
    "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Force push failed after rebase for ${branch_name}"
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
