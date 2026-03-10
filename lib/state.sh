#!/usr/bin/env bash
# State management for Autopilot.
# Handles pipeline initialization, state read/write (atomic), logging with
# rotation, status transitions, and counter helpers for retries/test fixes.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_STATE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_STATE_LOADED=1

# Source config for AUTOPILOT_* variables.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"

# Valid state transitions (from→to).
readonly _VALID_TRANSITIONS="
pending:implementing
pending:completed
implementing:test_fixing
implementing:pr_open
implementing:pending
test_fixing:pr_open
test_fixing:pending
pr_open:reviewed
pr_open:test_fixing
reviewed:fixing
reviewed:fixed
fixing:fixed
fixing:reviewed
fixing:pending
fixed:merging
fixed:reviewed
fixed:test_fixing
fixed:pending
merging:merged
merging:reviewed
merging:pending
merged:pending
merged:completed
"

# --- Initialization ---

# Create the .autopilot/ directory tree and initial state.json.
init_pipeline() {
  local project_dir="${1:-.}"
  local state_dir="${project_dir}/.autopilot"

  mkdir -p "${state_dir}/logs" "${state_dir}/locks"

  if [[ ! -f "${state_dir}/state.json" ]]; then
    _write_state_file "${state_dir}/state.json" \
      '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}'
  fi
}

# --- State Read/Write (Atomic) ---

# Validate that a field name contains only safe identifier characters.
_validate_field_name() {
  local field="$1"
  if [[ ! "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    return 1
  fi
}

# Read a field from state.json using jq.
read_state() {
  local project_dir="${1:-.}"
  local field="$2"
  local state_file="${project_dir}/.autopilot/state.json"

  if ! _validate_field_name "$field"; then
    log_msg "$project_dir" "ERROR" "Invalid field name: ${field}"
    return 1
  fi

  if [[ ! -f "$state_file" ]]; then
    echo ""
    return 1
  fi

  jq -r ".${field} // empty" "$state_file" 2>/dev/null
}

# Apply an arbitrary jq transformation to state.json atomically.
_jq_transform_state() {
  local project_dir="$1"; shift
  local state_file="${project_dir}/.autopilot/state.json"
  local tmp_file="${state_file}.tmp.$$"
  if jq "$@" "$state_file" > "$tmp_file" 2>/dev/null; then
    mv -f "$tmp_file" "$state_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Atomically write a field to state.json using the given jq arg type.
_write_state_field() {
  local project_dir="${1:-.}"
  local jq_flag="$2"
  local field="$3"
  local value="$4"

  if ! _validate_field_name "$field"; then
    log_msg "$project_dir" "ERROR" "Invalid field name: ${field}"
    return 1
  fi

  if [[ ! -f "${project_dir}/.autopilot/state.json" ]]; then
    log_msg "$project_dir" "ERROR" "state.json not found — run init_pipeline first"
    return 1
  fi

  if ! _jq_transform_state "$project_dir" "$jq_flag" v "$value" ".${field} = \$v"; then
    log_msg "$project_dir" "ERROR" "Failed to write state field: ${field}"
    return 1
  fi
}

# Write a string field to state.json atomically (tmp file + mv).
write_state() { _write_state_field "${1:-.}" "--arg" "$2" "$3"; }

# Write a numeric field to state.json atomically.
write_state_num() { _write_state_field "${1:-.}" "--argjson" "$2" "$3"; }

# Atomically write raw JSON content to a state file.
_write_state_file() {
  local target_file="$1"
  local content="$2"
  local tmp_file="${target_file}.tmp.$$"

  echo "$content" > "$tmp_file"
  mv -f "$tmp_file" "$target_file"
}

# --- Logging ---

# Log a message to pipeline.log with timestamp and level, rotating if needed.
log_msg() {
  local project_dir="${1:-.}"
  local level="$2"
  local message="$3"
  local log_dir="${project_dir}/.autopilot/logs"
  local log_file="${log_dir}/pipeline.log"

  # Ensure log directory exists (cache check avoids fork on every call).
  [[ -d "$log_dir" ]] || mkdir -p "$log_dir"

  # Cache timestamp to avoid forking date on every log call.
  # Refresh at most once per second (uses SECONDS builtin).
  local timestamp
  if [[ "${_LOG_LAST_SEC:-}" != "$SECONDS" ]]; then
    _LOG_CACHED_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    _LOG_LAST_SEC="$SECONDS"
  fi
  timestamp="$_LOG_CACHED_TS"
  echo "${timestamp} [${level}] ${message}" >> "$log_file"

  # Rotate only every 1000 messages (tracked via counter) to avoid
  # wc -l fork on every log call.
  _LOG_MSG_COUNT=$(( ${_LOG_MSG_COUNT:-0} + 1 ))
  if (( _LOG_MSG_COUNT >= 1000 )); then
    _LOG_MSG_COUNT=0
    _rotate_log "$log_file"
  fi
}

# Rotate log file if it exceeds AUTOPILOT_MAX_LOG_LINES.
_rotate_log() {
  local log_file="$1"
  local max_lines="${AUTOPILOT_MAX_LOG_LINES:-50000}"

  [[ ! -f "$log_file" ]] && return 0

  local line_count
  line_count="$(wc -l < "$log_file" | tr -d ' ')"

  if [[ "$line_count" -gt "$max_lines" ]]; then
    local keep_lines=$(( max_lines / 2 ))
    local tmp_file="${log_file}.rotate.$$"
    tail -n "$keep_lines" "$log_file" > "$tmp_file"
    mv -f "$tmp_file" "$log_file"
  fi
}

# --- Status Transitions ---

# Update pipeline status with transition validation.
update_status() {
  local project_dir="${1:-.}"
  local new_status="$2"

  local current_status
  current_status="$(read_state "$project_dir" "status")"

  if ! _is_valid_transition "$current_status" "$new_status"; then
    log_msg "$project_dir" "ERROR" \
      "Invalid transition: ${current_status} -> ${new_status}"
    return 1
  fi

  if ! write_state "$project_dir" "status" "$new_status"; then
    log_msg "$project_dir" "ERROR" "Failed to write status: ${new_status}"
    return 1
  fi
  log_msg "$project_dir" "INFO" "Status: ${current_status} -> ${new_status}"
}

# Check if a state transition is valid.
_is_valid_transition() {
  local from="$1"
  local to="$2"
  local pair="${from}:${to}"

  echo "$_VALID_TRANSITIONS" | grep -qFx "${pair}"
}

# --- Generic Counter Helpers ---

# Read a counter value from state.json (defaults to 0).
_get_counter() {
  local project_dir="$1"
  local field="$2"
  local value

  value="$(read_state "$project_dir" "$field")"
  if [[ -z "$value" ]]; then
    echo "0"
  else
    echo "$value"
  fi
}

# Increment a counter in state.json by 1.
_increment_counter() {
  local project_dir="$1"
  local field="$2"
  local current

  current="$(_get_counter "$project_dir" "$field")"
  local new_value=$(( current + 1 ))
  write_state_num "$project_dir" "$field" "$new_value"
}

# Reset a counter in state.json to 0.
_reset_counter() {
  local project_dir="$1"
  local field="$2"

  write_state_num "$project_dir" "$field" 0
}

# --- Increment-and-Log Helper ---

# Increment a counter and log a warning with the new value and max.
_increment_and_log_counter() {
  local project_dir="${1:-.}"
  local field="$2"
  local label="$3"
  local max_val="$4"
  _increment_counter "$project_dir" "$field"
  local new_val
  new_val="$(_get_counter "$project_dir" "$field")"
  log_msg "$project_dir" "WARNING" "${label} incremented to ${new_val}/${max_val}"
}

# --- Retry Tracking (Public API) ---

# Get the current retry count for the active task.
get_retry_count() { _get_counter "${1:-.}" "retry_count"; }

# Increment the retry count for the active task.
increment_retry() {
  _increment_and_log_counter "${1:-.}" "retry_count" \
    "Retry" "${AUTOPILOT_MAX_RETRIES}"
}

# Reset the retry count (e.g., when advancing to next task).
reset_retry() { _reset_counter "${1:-.}" "retry_count"; }

# --- Test Fix Retry Tracking (Public API) ---

# Get the current test fix retry count.
get_test_fix_retries() { _get_counter "${1:-.}" "test_fix_retries"; }

# Increment the test fix retry count.
increment_test_fix_retries() {
  _increment_and_log_counter "${1:-.}" "test_fix_retries" \
    "Test fix retry" "${AUTOPILOT_MAX_TEST_FIX_RETRIES}"
}

# Reset the test fix retry count.
reset_test_fix_retries() { _reset_counter "${1:-.}" "test_fix_retries"; }

# --- Reviewer Retry Tracking (Public API) ---

# Get the current reviewer consecutive failure count.
get_reviewer_retries() { _get_counter "${1:-.}" "reviewer_retry_count"; }

# Increment the reviewer retry count on consecutive failures.
increment_reviewer_retries() {
  _increment_and_log_counter "${1:-.}" "reviewer_retry_count" \
    "Reviewer retry" "${AUTOPILOT_MAX_REVIEWER_RETRIES:-5}"
}

# Reset the reviewer retry count (e.g., on successful review).
reset_reviewer_retries() { _reset_counter "${1:-.}" "reviewer_retry_count"; }

# --- Network Retry Tracking (Public API) ---

# Get the current network retry count.
get_network_retries() { _get_counter "${1:-.}" "network_retry_count"; }

# Increment the network retry count on consecutive network failures.
increment_network_retries() {
  _increment_and_log_counter "${1:-.}" "network_retry_count" \
    "Network retry" "${AUTOPILOT_MAX_NETWORK_RETRIES:-20}"
}

# Reset the network retry count (e.g., on successful operation).
reset_network_retries() { _reset_counter "${1:-.}" "network_retry_count"; }

# --- Lock Management ---

# Acquire a named lock atomically. Writes PID to lockfile. Returns 1 if held.
acquire_lock() {
  local project_dir="${1:-.}"
  local lock_name="${2:-pipeline}"
  local lock_dir="${project_dir}/.autopilot/locks"
  local lock_file="${lock_dir}/${lock_name}.lock"

  mkdir -p "$lock_dir"

  # Atomic creation via noclobber — prevents TOCTOU race between processes
  if (set -C; echo "$$" > "$lock_file") 2>/dev/null; then
    return 0
  fi

  # Lock file exists — check if stale
  local existing_pid
  existing_pid="$(cat "$lock_file" 2>/dev/null)"

  if _is_lock_stale "$project_dir" "$lock_file" "$existing_pid"; then
    log_msg "$project_dir" "WARNING" \
      "Removing stale lock ${lock_name} (pid=${existing_pid})"
    rm -f "$lock_file"
    # Retry atomic creation (another process may have grabbed it)
    if (set -C; echo "$$" > "$lock_file") 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# Release a named lock. Only releases if we own it (PID matches).
release_lock() {
  local project_dir="${1:-.}"
  local lock_name="${2:-pipeline}"
  local lock_file="${project_dir}/.autopilot/locks/${lock_name}.lock"

  if [[ ! -f "$lock_file" ]]; then
    return 0
  fi

  local lock_pid
  lock_pid="$(cat "$lock_file" 2>/dev/null)"

  if [[ "$lock_pid" = "$$" ]]; then
    rm -f "$lock_file"
  else
    log_msg "$project_dir" "WARNING" \
      "Cannot release lock ${lock_name}: owned by pid ${lock_pid}, we are $$"
    return 1
  fi
}

# Check if a lock is stale (dead PID or age exceeds threshold).
_is_lock_stale() {
  local project_dir="$1"
  local lock_file="$2"
  local lock_pid="$3"
  local stale_minutes
  # Use explicit override if set, otherwise derive from agent timeouts
  if [[ -n "${AUTOPILOT_STALE_LOCK_MINUTES:-}" ]]; then
    stale_minutes="$AUTOPILOT_STALE_LOCK_MINUTES"
  else
    stale_minutes="$(_compute_stale_lock_minutes)"
  fi

  # Empty PID means lock is corrupt/stale — treat as stale
  [[ -z "$lock_pid" ]] && return 0

  # Check if PID is dead (ps -p works without signal permission, unlike kill -0)
  if ! ps -p "$lock_pid" >/dev/null 2>&1; then
    return 0
  fi

  # Check file age against stale threshold
  if _is_lock_file_old "$lock_file" "$stale_minutes"; then
    return 0
  fi

  # Lock is held by a live process and is not old
  return 1
}

# Check if a lock file is older than the given threshold in minutes.
_is_lock_file_old() {
  local lock_file="$1"
  local stale_minutes="$2"

  [[ ! -f "$lock_file" ]] && return 1

  local now file_mtime age_seconds stale_seconds
  now="$(date +%s)"
  stale_seconds=$(( stale_minutes * 60 ))

  # macOS and GNU stat have different syntax
  if stat -f '%m' "$lock_file" >/dev/null 2>&1; then
    # macOS/BSD stat
    file_mtime="$(stat -f '%m' "$lock_file")"
  else
    # GNU stat
    file_mtime="$(stat -c '%Y' "$lock_file")"
  fi

  age_seconds=$(( now - file_mtime ))
  [[ "$age_seconds" -ge "$stale_seconds" ]]
}
