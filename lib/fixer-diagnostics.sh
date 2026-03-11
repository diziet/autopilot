#!/usr/bin/env bash
# Fixer diagnostics and health checks for Autopilot.
# Pre-spawn validation, post-spawn logging, stderr preservation,
# and empty-output retry backoff.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_FIXER_DIAGNOSTICS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_FIXER_DIAGNOSTICS_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# --- Fixer Health Check ---

# Validate fixer prerequisites before spawning. Returns 1 on failure.
_fixer_health_check() {
  local project_dir="$1"
  local user_prompt="$2"
  local config_dir="${3:-}"

  if [[ -z "$user_prompt" ]]; then
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

  local output_size=0
  if [[ -f "$output_file" ]]; then
    output_size=$(wc -c < "$output_file" | tr -d ' ')
  fi

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

  local output_size=0
  if [[ -f "$output_file" ]]; then
    output_size=$(wc -c < "$output_file" | tr -d ' ')
  fi

  if [[ "$output_size" -eq 0 ]]; then
    local log_dir="${project_dir}/.autopilot/logs"
    mkdir -p "$log_dir"
    cp -f "$stderr_file" "${log_dir}/fixer-task-${task_number}-stderr.log"
    log_msg "$project_dir" "WARNING" \
      "Fixer produced 0 output — stderr preserved to fixer-task-${task_number}-stderr.log"
  fi
}

# Apply retry backoff when fixer produced empty output.
_fixer_empty_output_backoff() {
  local project_dir="$1"
  local output_file="$2"
  local retry_delay="${3:-30}"

  local output_size=0
  if [[ -f "$output_file" ]]; then
    output_size=$(wc -c < "$output_file" | tr -d ' ')
  fi

  if [[ "$output_size" -eq 0 ]]; then
    log_msg "$project_dir" "WARNING" \
      "Fixer empty output — waiting ${retry_delay}s before returning (transient issue backoff)"
    sleep "$retry_delay"
    return 0
  fi

  return 1
}
