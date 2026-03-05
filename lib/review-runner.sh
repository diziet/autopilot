#!/usr/bin/env bash
# Review runner for Autopilot — cron and standalone review orchestration.
# Provides _run_cron_review (detects pr_open, runs full cycle) and
# _run_standalone_review (ad-hoc review of any PR by number).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_REVIEW_RUNNER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_REVIEW_RUNNER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/reviewer.sh
source "${BASH_SOURCE[0]%/*}/reviewer.sh"
# shellcheck source=lib/reviewer-posting.sh
source "${BASH_SOURCE[0]%/*}/reviewer-posting.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# Exit code constants for the review runner.
readonly REVIEW_OK=0
readonly REVIEW_SKIP=1
readonly REVIEW_ERROR=2

# --- Cron Mode ---

# Run a cron review cycle: detect pr_open state, run reviewers, post comments.
_run_cron_review() {
  local project_dir="$1"

  # Only act when the pipeline is in pr_open state.
  local status
  status="$(read_state "$project_dir" "status")"
  if [[ "$status" != "pr_open" ]]; then
    log_msg "$project_dir" "DEBUG" \
      "Review cron: state is '${status}', not pr_open — skipping"
    return "$REVIEW_SKIP"
  fi

  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"
  if [[ -z "$pr_number" ]] || [[ "$pr_number" == "0" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Review cron: pr_open state but no pr_number in state.json"
    return "$REVIEW_ERROR"
  fi

  log_msg "$project_dir" "INFO" \
    "Review cron: running review cycle for PR #${pr_number}"

  _execute_review_cycle "$project_dir" "$pr_number" "cron"
}

# --- Standalone Mode ---

# Run an ad-hoc review of a specific PR by number.
_run_standalone_review() {
  local project_dir="$1"
  local pr_number="$2"

  # Validate PR number is numeric.
  if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Standalone review: invalid PR number '${pr_number}'"
    return "$REVIEW_ERROR"
  fi

  log_msg "$project_dir" "INFO" \
    "Standalone review: running review for PR #${pr_number}"

  _execute_review_cycle "$project_dir" "$pr_number" "standalone"
}

# --- Review Cycle ---

# Execute the full review cycle: fetch diff, run reviewers, post comments.
_execute_review_cycle() {
  local project_dir="$1"
  local pr_number="$2"
  local mode="$3"

  # Fetch PR diff.
  local diff_file
  diff_file="$(fetch_pr_diff "$project_dir" "$pr_number")" || {
    local exit_code=$?
    if [[ "$exit_code" -eq 2 ]]; then
      log_msg "$project_dir" "WARNING" \
        "Review: diff too large for PR #${pr_number} — skipping"
    else
      log_msg "$project_dir" "ERROR" \
        "Review: failed to fetch diff for PR #${pr_number}"
    fi
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Get the current head SHA for dedup tracking.
  local head_sha
  head_sha="$(_get_pr_head_sha "$project_dir" "$pr_number")" || true
  if [[ -z "$head_sha" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Review: could not determine head SHA for PR #${pr_number} — using placeholder"
    head_sha="unknown"
  fi

  # Run all configured reviewers in parallel.
  local result_dir
  result_dir="$(run_reviewers "$project_dir" "$pr_number" "$diff_file")" || {
    log_msg "$project_dir" "ERROR" \
      "Review: reviewer execution failed for PR #${pr_number}"
    _cleanup_diff_file "$diff_file"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Post review comments (handles dedup, clean detection).
  post_review_comments "$project_dir" "$pr_number" "$head_sha" "$result_dir" || {
    log_msg "$project_dir" "ERROR" \
      "Review: failed to post comments for PR #${pr_number}"
    _cleanup_diff_file "$diff_file"
    _cleanup_result_dir "$result_dir"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Transition state: cron mode moves to reviewed, standalone does nothing.
  _transition_after_review "$project_dir" "$mode"

  # Clean up temp files.
  _cleanup_diff_file "$diff_file"
  _cleanup_result_dir "$result_dir"

  log_msg "$project_dir" "INFO" \
    "Review complete for PR #${pr_number} (mode=${mode})"
  return "$REVIEW_OK"
}

# --- State Transitions ---

# Transition pipeline state after a successful review (cron mode only).
_transition_after_review() {
  local project_dir="$1"
  local mode="$2"

  # Only cron mode modifies pipeline state.
  [[ "$mode" != "cron" ]] && return 0

  local current_status
  current_status="$(read_state "$project_dir" "status")"
  if [[ "$current_status" == "pr_open" ]]; then
    update_status "$project_dir" "reviewed"
  fi
}

# Handle state transition on error (cron mode only).
_transition_on_error() {
  local project_dir="$1"
  local mode="$2"

  # Standalone mode doesn't touch pipeline state.
  [[ "$mode" != "cron" ]] && return 0

  # On error, stay in pr_open — next tick will retry.
  log_msg "$project_dir" "DEBUG" \
    "Review error: staying in pr_open for retry"
}

# --- PR SHA Helpers ---

# Get the head SHA for a PR via gh API.
_get_pr_head_sha() {
  local project_dir="$1"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || return 1

  local sha
  sha="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1

  echo "$sha"
}

# --- Cleanup Helpers ---

# Remove the temporary diff file.
_cleanup_diff_file() {
  local diff_file="$1"
  if [[ -n "$diff_file" ]] && [[ -f "$diff_file" ]]; then
    rm -f "$diff_file"
  fi
}

# Remove the temporary result directory.
_cleanup_result_dir() {
  local result_dir="$1"
  if [[ -n "$result_dir" ]] && [[ -d "$result_dir" ]]; then
    rm -rf "$result_dir"
  fi
}
