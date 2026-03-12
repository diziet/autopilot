#!/usr/bin/env bash
# Async execution for spec compliance review.
# Spawns run_spec_review in the background and tracks completion via PID file.
# Called from lib/spec-review.sh — depends on functions and constants defined there.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_SPEC_REVIEW_ASYNC_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_SPEC_REVIEW_ASYNC_LOADED=1

# --- PID File Paths ---

# Path to the PID file for background spec review.
_spec_review_pid_file() {
  local project_dir="${1:-.}"
  echo "${project_dir}/.autopilot/spec-review.pid"
}

# Path to the exit code file for background spec review.
_spec_review_exit_file() {
  local project_dir="${1:-.}"
  echo "${project_dir}/.autopilot/spec-review.exit"
}

# Path to the stderr capture log for background spec review.
_spec_review_stderr_path() {
  local project_dir="${1:-.}"
  echo "${project_dir}/.autopilot/logs/spec-review-stderr.log"
}

# --- Async Launcher ---

# Spawn spec review in the background, writing PID to a tracking file.
run_spec_review_async() {
  local project_dir="${1:-.}"
  local task_number="$2"

  # Validate task number.
  if [[ ! "$task_number" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Invalid task number for async spec review: ${task_number}"
    return "$SPEC_REVIEW_ERROR"
  fi

  local pid_file
  pid_file="$(_spec_review_pid_file "$project_dir")"
  local exit_file
  exit_file="$(_spec_review_exit_file "$project_dir")"

  # Skip if a review is already running.
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(cat "$pid_file" 2>/dev/null)" || true
    if [[ -n "$existing_pid" && "$existing_pid" =~ ^[0-9]+$ ]] \
        && kill -0 "$existing_pid" 2>/dev/null; then
      log_msg "$project_dir" "INFO" \
        "Spec review already running (PID=${existing_pid}) — skipping"
      return 0
    fi
  fi

  # Clean up stale exit file from previous run.
  rm -f "$exit_file"

  # Stderr log for the background subshell (captures errors that would otherwise be lost).
  local stderr_log
  stderr_log="$(_spec_review_stderr_path "$project_dir")"
  mkdir -p "${project_dir}/.autopilot/logs"

  # Spawn run_spec_review in a subshell background process.
  # Use set +e so the exit code capture line runs even on non-zero returns.
  # Redirect stderr to a log file so failures are visible.
  (
    set +e
    run_spec_review "$project_dir" "$task_number"
    echo "$?" > "$exit_file"
  ) 2>"$stderr_log" &
  local bg_pid=$!

  # Write PID to tracking file.
  echo "$bg_pid" > "$pid_file"

  log_msg "$project_dir" "INFO" \
    "Spec review spawned in background for task ${task_number} (PID=${bg_pid})"
  return 0
}

# --- Completion Check ---

# Check if a background spec review has completed.
# Returns 0 if completed (or no review running), 1 if still in progress.
check_spec_review_completion() {
  local project_dir="${1:-.}"
  local pid_file
  pid_file="$(_spec_review_pid_file "$project_dir")"

  # No PID file means no async review was started.
  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  local bg_pid
  bg_pid="$(cat "$pid_file" 2>/dev/null)" || {
    rm -f "$pid_file"
    return 0
  }

  # Empty or non-numeric PID — clean up.
  if [[ -z "$bg_pid" || ! "$bg_pid" =~ ^[0-9]+$ ]]; then
    rm -f "$pid_file"
    return 0
  fi

  # Check if the process is still running.
  if kill -0 "$bg_pid" 2>/dev/null; then
    log_msg "$project_dir" "DEBUG" \
      "Spec review still running (PID=${bg_pid})"
    return 1
  fi

  # Process finished — read exit code and clean up.
  local exit_file
  exit_file="$(_spec_review_exit_file "$project_dir")"
  local exit_code="0"
  if [[ -f "$exit_file" ]]; then
    exit_code="$(cat "$exit_file" 2>/dev/null)" || exit_code="0"
  fi

  log_msg "$project_dir" "INFO" \
    "Background spec review completed (PID=${bg_pid}, exit=${exit_code})"

  # Log captured stderr for diagnosis (WARNING on failure, DEBUG on success).
  local stderr_log
  stderr_log="$(_spec_review_stderr_path "$project_dir")"
  if [[ "$exit_code" != "0" ]]; then
    _log_file_tail "$project_dir" "WARNING" \
      "Spec review background stderr" "$stderr_log"
  elif [[ -f "$stderr_log" && -s "$stderr_log" ]]; then
    _log_file_tail "$project_dir" "DEBUG" \
      "Spec review background stderr (success)" "$stderr_log"
  fi
  rm -f "$stderr_log"

  rm -f "$pid_file" "$exit_file"
  return 0
}
