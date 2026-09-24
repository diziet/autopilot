#!/usr/bin/env bash
# Merge execution for Autopilot's merger: reopen a closed PR, convert a draft,
# wait for GitHub's mergeable status, and squash-merge via `gh pr merge --squash`.
# Split from lib/merger.sh to keep files under 400 lines.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_MERGE_PR_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_MERGE_PR_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/rebase.sh
source "${BASH_SOURCE[0]%/*}/rebase.sh"
# shellcheck source=lib/gh.sh
source "${BASH_SOURCE[0]%/*}/gh.sh"

# --- Pre-Merge Checks ---

# Ensure PR is open and not a draft before attempting merge; reopen if closed.
_ensure_pr_open_for_merge() {
  local project_dir="$1"
  local pr_number="$2"
  local repo="$3"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local pr_json stderr_file pr_state is_draft
  stderr_file="$(mktemp)"
  if ! pr_json="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json state,isDraft \
    --jq '{state: .state, isDraft: .isDraft}' 2>"$stderr_file")"; then
    local view_stderr
    view_stderr="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    log_msg "$project_dir" "WARNING" \
      "Could not determine state of PR #${pr_number}${view_stderr:+: ${view_stderr}} — proceeding"
    return 0
  else
    rm -f "$stderr_file"
  fi

  pr_state="$(echo "$pr_json" | jq -r '.state // empty' 2>/dev/null)" || true
  is_draft="$(echo "$pr_json" | jq -r '.isDraft // false' 2>/dev/null)" || true

  if [[ -z "$pr_state" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Could not determine state of PR #${pr_number} — proceeding"
  fi

  if [[ "$pr_state" == "CLOSED" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} is closed — attempting reopen"
    local reopen_stderr
    reopen_stderr="$(timeout "$timeout_gh" gh pr reopen "$pr_number" \
      --repo "$repo" 2>&1 1>/dev/null)" || {
      log_msg "$project_dir" "ERROR" \
        "Failed to reopen PR #${pr_number}: ${reopen_stderr}"
      return 1
    }
    # Wait for GitHub to process the reopen.
    sleep 3
  fi

  # Convert a draft PR to ready before the merge attempt.
  if [[ "$is_draft" == "true" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} is still a draft — converting to ready before merge"
    if ! _run_gh "$project_dir" timeout "$timeout_gh" gh pr ready "$pr_number" \
      --repo "$repo"; then
      log_msg "$project_dir" "ERROR" \
        "Failed to convert draft PR #${pr_number} to ready"
      return 1
    fi
    sleep 3
  fi

  return 0
}

# Poll the mergeable status while it is UNKNOWN, for up to
# AUTOPILOT_MERGE_WAIT_TIMEOUT seconds (default 30). Always returns 0.
_poll_mergeability() {
  local project_dir="$1"
  local pr_number="$2"
  local max_wait="${AUTOPILOT_MERGE_WAIT_TIMEOUT:-30}"
  local poll_interval="${AUTOPILOT_MERGE_POLL_INTERVAL:-5}"

  local status
  status="$(check_pr_mergeable "$project_dir" "$pr_number")"

  if [[ "$status" != "$PR_MERGEABLE_UNKNOWN" ]]; then
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "PR #${pr_number} mergeable status is UNKNOWN — polling up to ${max_wait}s"

  local elapsed=0
  while [[ "$elapsed" -lt "$max_wait" ]]; do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    status="$(check_pr_mergeable "$project_dir" "$pr_number")"
    if [[ "$status" != "$PR_MERGEABLE_UNKNOWN" ]]; then
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} mergeable status resolved to ${status} after ${elapsed}s"
      return 0
    fi
  done

  log_msg "$project_dir" "WARNING" \
    "PR #${pr_number} mergeable status still UNKNOWN after ${max_wait}s — proceeding"
  return 0
}

# --- Squash Merge ---

# Squash-merge a PR via gh CLI.
squash_merge_pr() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for merge"
    return 1
  }

  _ensure_pr_open_for_merge "$project_dir" "$pr_number" "$repo" || return 1

  # Poll mergeability if UNKNOWN.
  _poll_mergeability "$project_dir" "$pr_number"

  log_msg "$project_dir" "INFO" "Squash-merging PR #${pr_number} in ${repo}"

  local merge_stderr
  merge_stderr="$(timeout "$timeout_gh" gh pr merge "$pr_number" \
    --squash --delete-branch \
    --repo "$repo" 2>&1 1>/dev/null)" || {
    log_msg "$project_dir" "ERROR" \
      "Failed to squash-merge PR #${pr_number}: ${merge_stderr}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Successfully merged PR #${pr_number}"
}
