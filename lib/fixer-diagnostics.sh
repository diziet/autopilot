#!/usr/bin/env bash
# Fixer diagnostics and health checks for Autopilot.
# Pre-spawn validation, post-spawn logging, stderr preservation,
# empty-output retry backoff, and session resume fallback detection.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_FIXER_DIAGNOSTICS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_FIXER_DIAGNOSTICS_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# --- Helpers ---

# Get file size in bytes, or 0 if file is missing.
_get_file_size() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -c < "$file" | tr -d ' '
  else
    echo 0
  fi
}

# --- Fixer Health Check ---

# Validate fixer prerequisites before spawning. Returns 1 on failure.
_fixer_health_check() {
  local project_dir="$1"
  local user_prompt="$2"
  local config_dir="${3:-}"

  if [[ ! "$user_prompt" =~ [^[:space:]] ]]; then
    log_msg "$project_dir" "ERROR" \
      "Fixer prompt is empty — skipping spawn"
    return 1
  fi

  if [[ -n "$config_dir" ]] && [[ ! -d "$config_dir" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Fixer config dir does not exist: ${config_dir} — skipping spawn"
    return 1
  fi

  return 0
}

# --- Fixer Post-Spawn Diagnostics ---

# Log post-fixer diagnostics: exit code, output size, JSON validity.
_log_fixer_diagnostics() {
  local project_dir="$1"
  local task_number="$2"
  local exit_code="$3"
  local output_file="$4"

  local output_size
  output_size="$(_get_file_size "$output_file")"

  local is_valid_json="false"
  if [[ "$output_size" -gt 0 ]] && jq empty "$output_file" 2>/dev/null; then
    is_valid_json="true"
  fi

  log_msg "$project_dir" "INFO" \
    "METRICS: fixer result task=${task_number} exit=${exit_code} output_bytes=${output_size} valid_json=${is_valid_json}"
}

# Preserve fixer stderr to logs when output is empty.
_preserve_fixer_stderr() {
  local project_dir="$1"
  local task_number="$2"
  local output_file="$3"

  local stderr_file="${output_file}.err"
  [[ -f "$stderr_file" ]] || return 0

  local output_size
  output_size="$(_get_file_size "$output_file")"

  if [[ "$output_size" -eq 0 ]]; then
    local log_dir="${project_dir}/.autopilot/logs"
    mkdir -p "$log_dir"
    cp -f "$stderr_file" "${log_dir}/fixer-task-${task_number}-stderr.log"
    log_msg "$project_dir" "WARNING" \
      "Fixer produced 0 output — stderr preserved to fixer-task-${task_number}-stderr.log"
  fi
}

# Apply retry backoff when fixer produced empty output. Always returns 0.
_fixer_empty_output_backoff() {
  local project_dir="$1"
  local output_file="$2"
  local retry_delay="$3"

  local output_size
  output_size="$(_get_file_size "$output_file")"

  if [[ "$output_size" -eq 0 ]]; then
    log_msg "$project_dir" "WARNING" \
      "Fixer empty output — waiting ${retry_delay}s before returning (transient issue backoff)"
    sleep "$retry_delay"
  fi
}

# --- Session Resume ---

# Look up a session ID from a Claude JSON output file.
_extract_session_id() {
  local json_file="$1"

  [[ -f "$json_file" ]] || return 1

  local session_id
  session_id="$(jq -r '.session_id // empty' "$json_file" 2>/dev/null)"
  if [[ -n "$session_id" ]]; then
    echo "$session_id"
    return 0
  fi

  return 1
}

# Resolve a session ID for resuming. Lookup chain: fixer → coder → cold.
_resolve_session_id() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local log_dir="${project_dir}/.autopilot/logs"

  local fixer_json="${log_dir}/fixer-task-${task_number}.json"
  local coder_json="${log_dir}/coder-task-${task_number}.json"

  # Try fixer output first (subsequent fix iterations).
  local session_id
  session_id="$(_extract_session_id "$fixer_json")" && {
    echo "${session_id}:fixer"
    return 0
  }

  # Try coder output (first fix after coding).
  session_id="$(_extract_session_id "$coder_json")" && {
    echo "${session_id}:coder"
    return 0
  }

  # Cold start — no session to resume.
  return 1
}

# --- Session Resume Fallback ---

# Check if stderr indicates a missing/expired Claude session.
_check_session_not_found() {
  local stderr_file="$1"

  [[ -f "$stderr_file" ]] || return 1
  grep -qi "No conversation found" "$stderr_file" 2>/dev/null
}

# Delete stale coder/fixer JSON files that contain a bad session ID.
_delete_stale_session_files() {
  local project_dir="$1"
  local task_number="$2"
  local log_dir="${project_dir}/.autopilot/logs"

  local fixer_json="${log_dir}/fixer-task-${task_number}.json"
  local coder_json="${log_dir}/coder-task-${task_number}.json"

  rm -f "$fixer_json" "$coder_json"
  log_msg "$project_dir" "INFO" \
    "Deleted stale session files for task ${task_number}"
}
