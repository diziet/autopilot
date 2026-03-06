#!/usr/bin/env bash
# Dispatch helper functions and terminal state handlers.
# Split from dispatch-handlers.sh: _handle_merged, _handle_completed,
# retry/diagnosis logic, PR number extraction, and clean review checks.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DISPATCH_HELPERS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DISPATCH_HELPERS_LOADED=1

# --- merged: record metrics, generate summary, advance task ---

# Handle merged: record metrics, generate summary in background, advance.
_handle_merged() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"

  # Record phase transition from merging.
  record_phase_transition "$project_dir" "merging"

  # Fetch repo slug for metrics.
  local repo
  repo="$(get_repo_slug "$project_dir")" || repo=""

  # Record task completion metrics.
  record_task_complete "$project_dir" "$task_number" \
    "$pr_number" "$repo" "merged" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to record metrics for task ${task_number}"
  }

  # Record phase timing.
  record_phase_durations "$project_dir" "$task_number" "$pr_number" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to record phase durations for task ${task_number}"
  }

  # Generate task summary in the background (non-blocking).
  local task_title=""
  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)" || true
  if [[ -n "$tasks_file" ]]; then
    task_title="$(extract_task_title "$tasks_file" "$task_number")" || true
  fi
  generate_task_summary_bg "$project_dir" "$task_number" \
    "$pr_number" "$task_title"

  # Check for completion of any previous background spec review.
  check_spec_review_completion "$project_dir" || true

  # Launch spec review asynchronously if interval reached.
  if should_run_spec_review "$task_number"; then
    log_msg "$project_dir" "INFO" \
      "Launching async spec compliance review after task ${task_number}"
    run_spec_review_async "$project_dir" "$task_number" || {
      log_msg "$project_dir" "WARNING" \
        "Failed to launch async spec review for task ${task_number}"
    }
  fi

  # Advance to next task.
  local next_task=$(( task_number + 1 ))
  write_state_num "$project_dir" "current_task" "$next_task"
  reset_retry "$project_dir"
  reset_test_fix_retries "$project_dir"
  reset_phase_durations "$project_dir"

  log_msg "$project_dir" "INFO" \
    "Task ${task_number} complete — advancing to task ${next_task}"

  # Check if all tasks are done.
  local tasks_file_check
  tasks_file_check="$(detect_tasks_file "$project_dir")" || true
  if [[ -n "$tasks_file_check" ]]; then
    local total_tasks
    total_tasks="$(count_tasks "$tasks_file_check")"
    if [[ "$next_task" -gt "$total_tasks" ]]; then
      update_status "$project_dir" "completed"
      return
    fi
  fi

  update_status "$project_dir" "pending"
}

# --- completed: terminal state ---

# Handle completed: all tasks done, exit cleanly.
_handle_completed() {
  local project_dir="$1"
  log_msg "$project_dir" "INFO" "Pipeline completed — all tasks done"
}

# --- Crash Recovery / Retry Helpers ---

# Handle crash recovery for any state where the agent process died mid-run.
_handle_crash_recovery() {
  local project_dir="$1"
  local state_name="$2"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found ${state_name} state on fresh tick for task ${task_number}"
  _retry_or_diagnose "$project_dir" "$task_number" "$state_name"
}

# Retry the current task or run diagnosis if retries exhausted.
_retry_or_diagnose() {
  local project_dir="$1"
  local task_number="$2"
  local current_state="$3"

  local retry_count
  retry_count="$(get_retry_count "$project_dir")"
  local max_retries="${AUTOPILOT_MAX_RETRIES:-5}"

  if [[ "$retry_count" -ge "$max_retries" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Max retries (${max_retries}) reached for task ${task_number}"

    # Run failure diagnosis.
    local task_body=""
    local tasks_file
    tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)" || true
    if [[ -n "$tasks_file" ]]; then
      task_body="$(extract_task "$tasks_file" "$task_number")" || true
    fi

    run_diagnosis "$project_dir" "$task_number" \
      "$task_body" "$current_state" >/dev/null 2>&1 || {
      log_msg "$project_dir" "WARNING" \
        "Diagnosis failed for task ${task_number}"
    }

    # Skip to next task after diagnosis.
    local next_task=$(( task_number + 1 ))
    write_state_num "$project_dir" "current_task" "$next_task"
    reset_retry "$project_dir"
    reset_test_fix_retries "$project_dir"
    reset_phase_durations "$project_dir"

    # Always transition to pending — _handle_pending will detect if all
    # tasks are done and transition to completed directly.
    update_status "$project_dir" "pending"
    return
  fi

  # Still have retries — increment and go back to pending.
  increment_retry "$project_dir"
  reset_test_fix_retries "$project_dir"

  # Transition back to pending for a fresh coder run.
  update_status "$project_dir" "pending"
}

# --- PR Number Extraction ---

# Extract PR number from a GitHub PR URL.
_extract_pr_number() {
  local pr_url="$1"

  # Match /pull/NNN at end of URL.
  if [[ "$pr_url" =~ /pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  # Fallback: try the last numeric segment.
  local num
  num="$(echo "$pr_url" | grep -oE '[0-9]+$')"
  if [[ -n "$num" ]]; then
    echo "$num"
    return 0
  fi

  echo "0"
  return 1
}

# --- Clean Review Detection ---

# Clear reviewed status for a PR so the fixer is forced to run.
_clear_reviewed_status() {
  local project_dir="$1"
  local pr_number="$2"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  [[ -f "$json_file" ]] || return 0

  local pr_key="pr_${pr_number}"
  local updated
  updated="$(jq "del(.\"${pr_key}\")" "$json_file" 2>/dev/null)" || return 0
  echo "$updated" > "$json_file"
  log_msg "$project_dir" "INFO" \
    "Cleared reviewed status for PR #${pr_number}"
}

# Check if all reviews for a PR were clean from reviewed.json.
_all_reviews_clean_from_json() {
  local project_dir="$1"
  local pr_number="$2"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  [[ -f "$json_file" ]] || return 1

  local pr_key="pr_${pr_number}"
  local json_content
  json_content="$(cat "$json_file" 2>/dev/null)" || return 1

  # Check that the PR key exists and has entries.
  local reviewer_count
  reviewer_count="$(jq -r ".\"${pr_key}\" | length // 0" \
    <<< "$json_content" 2>/dev/null)" || return 1
  [[ "$reviewer_count" -gt 0 ]] || return 1

  # Check that every reviewer's is_clean flag is true.
  local all_clean
  all_clean="$(jq -r "[.\"${pr_key}\" | to_entries[] | .value.is_clean] | all" \
    <<< "$json_content" 2>/dev/null)" || return 1
  [[ "$all_clean" == "true" ]]
}
