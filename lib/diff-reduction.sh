#!/usr/bin/env bash
# Diff-reduction reviewer for Autopilot — handles oversized PR diffs.
# Runs a specialized reviewer that suggests how to shrink the diff.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DIFF_REDUCTION_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DIFF_REDUCTION_LOADED=1

# Run a single diff-reduction reviewer against an oversized PR diff.
_run_diff_reduction_review() {
  local project_dir="$1"
  local pr_number="$2"
  local diff_file="$3"
  local mode="$4"

  # Extract task description for reviewer context.
  local task_description=""
  if [[ "$mode" != "standalone" ]]; then
    local task_number
    task_number="$(read_state "$project_dir" "current_task")" || true
    local tasks_file
    tasks_file="$(detect_tasks_file "$project_dir")" || true
    if [[ -n "$tasks_file" ]] && [[ -n "$task_number" ]]; then
      task_description="$(extract_task "$tasks_file" "$task_number")" || true
    fi
  fi

  # Build augmented diff with task description if available.
  local effective_diff="$diff_file"
  if [[ -n "$task_description" ]]; then
    effective_diff="$(mktemp "${TMPDIR:-/tmp}/autopilot-augmented-diff.XXXXXX")"
    {
      printf '%s\n' "## Task Description"
      printf '\n%s\n\n' "$task_description"
      printf '%s\n\n%s\n\n' "---" "## PR Diff (Sampled)"
      cat "$diff_file"
    } > "$effective_diff"
  fi

  # Temporarily override reviewers to use only diff-reduction persona.
  # Save and restore to avoid leaking into the caller's environment.
  local orig_reviewers="$AUTOPILOT_REVIEWERS"
  AUTOPILOT_REVIEWERS="diff-reduction"

  local result_dir
  result_dir="$(run_reviewers "$project_dir" "$pr_number" "$effective_diff")" || {
    AUTOPILOT_REVIEWERS="$orig_reviewers"
    log_msg "$project_dir" "ERROR" \
      "Review: diff-reduction reviewer failed for PR #${pr_number}"
    _cleanup_dr_files "$diff_file" "$effective_diff"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }
  AUTOPILOT_REVIEWERS="$orig_reviewers"

  # Record token usage.
  _record_reviewer_usage "$project_dir" "$result_dir"

  # Get head SHA for dedup tracking.
  local head_sha
  head_sha="$(_get_pr_head_sha "$project_dir" "$pr_number")" || true
  [[ -z "$head_sha" ]] && head_sha="unknown"

  # Post review comments.
  post_review_comments "$project_dir" "$pr_number" "$head_sha" "$result_dir" || {
    log_msg "$project_dir" "ERROR" \
      "Review: failed to post diff-reduction comments for PR #${pr_number}"
    _cleanup_dr_files "$diff_file" "$effective_diff"
    _cleanup_result_dir "$result_dir"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Transition state: cron mode moves to reviewed, standalone does nothing.
  _transition_after_review "$project_dir" "$mode"

  # Track that this was a diff-reduction review.
  # Retry counter is incremented here (not in _handle_diff_reduction_recheck).
  if [[ "$mode" == "cron" ]]; then
    write_state "$project_dir" "diff_reduction_active" "true"
    increment_diff_reduction_retries "$project_dir"
  fi

  # Clean up temp files.
  _cleanup_dr_files "$diff_file" "$effective_diff"
  _cleanup_result_dir "$result_dir"

  log_msg "$project_dir" "INFO" \
    "Diff-reduction review complete for PR #${pr_number} (mode=${mode})"
  return "$REVIEW_OK"
}

# Clean up diff and augmented-diff temp files.
_cleanup_dr_files() {
  local diff_file="$1"
  local effective_diff="$2"
  _cleanup_diff_file "$diff_file"
  if [[ "$effective_diff" != "$diff_file" ]]; then
    rm -f "$effective_diff"
  fi
}

# Check if the diff is still oversized after a fixer run.
# Returns: 0 = still oversized, 1 = now under limit, 2 = check failed (gh error).
check_diff_still_oversized() {
  local project_dir="$1"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local max_diff_bytes="${AUTOPILOT_MAX_DIFF_BYTES:-500000}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || return 2

  # Stream diff directly to wc -c to avoid holding the full diff in memory.
  # Use a subshell with pipefail so gh failures propagate through the pipe.
  local diff_bytes
  diff_bytes="$(set -o pipefail; timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo" 2>/dev/null | wc -c | tr -d ' ')" || return 2

  if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} diff still oversized after fix (${diff_bytes} bytes > ${max_diff_bytes} max)"
    return 0  # Still oversized.
  fi

  log_msg "$project_dir" "INFO" \
    "PR #${pr_number} diff now under limit (${diff_bytes} bytes <= ${max_diff_bytes} max)"
  return 1  # No longer oversized.
}
