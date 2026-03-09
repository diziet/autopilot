#!/usr/bin/env bash
# Per-task test output management for Autopilot.
# Saves, reads, and truncates test output for fixer/test-fixer prompts.
# Provides shared helpers for output validation and constants.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TEST_OUTPUT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TEST_OUTPUT_LOADED=1

# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Shared instruction text for test failure prompts.
readonly _TEST_FAILURE_INSTRUCTION="The following tests are failing. Some may be caused by your changes, others may be pre-existing. Fix all of them."

# Build the per-task test output file path.
_task_test_output_path() {
  local project_dir="$1"
  local task_number="$2"
  echo "${project_dir}/.autopilot/logs/test-output-task-${task_number}.txt"
}

# Validate that task_number is a non-negative integer.
_validate_test_output_task_number() {
  local task_number="$1"
  local project_dir="${2:-.}"
  if [[ ! "$task_number" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" "Invalid task number: ${task_number}"
    return 1
  fi
}

# Save the current test_gate_output.log as a per-task test output file.
save_task_test_output() {
  local project_dir="${1:-.}"
  local task_number="$2"
  _validate_test_output_task_number "$task_number" "$project_dir" || return 1
  local source_log="${project_dir}/.autopilot/test_gate_output.log"
  local dest
  dest="$(_task_test_output_path "$project_dir" "$task_number")"

  if [[ ! -f "$source_log" ]]; then
    log_msg "$project_dir" "WARNING" "No test_gate_output.log to save for task ${task_number}"
    return 1
  fi

  _ensure_task_output_dir "$project_dir"
  cp "$source_log" "$dest"
  log_msg "$project_dir" "INFO" "Saved test output for task ${task_number}"
}

# Save raw test output string as a per-task test output file.
save_task_test_output_raw() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local output="$3"
  _validate_test_output_task_number "$task_number" "$project_dir" || return 1
  local dest
  dest="$(_task_test_output_path "$project_dir" "$task_number")"

  _ensure_task_output_dir "$project_dir"
  printf '%s\n' "$output" > "$dest"
  log_msg "$project_dir" "INFO" "Saved test output for task ${task_number}"
}

# Ensure the logs directory exists.
_ensure_task_output_dir() {
  mkdir -p "${1}/.autopilot/logs"
}

# Truncate text to max_lines from the tail. Echoes truncated text to stdout.
# If truncated, appends a sentinel line "---TRUNCATED_FROM:<N>---" as the last line.
truncate_test_output() {
  local input="$1"
  local max_lines="${2:-${AUTOPILOT_MAX_TEST_OUTPUT:-500}}"

  local total_lines
  total_lines="$(printf '%s\n' "$input" | wc -l | tr -d ' ')"

  if [[ "$total_lines" -gt "$max_lines" ]]; then
    printf '%s\n' "$input" | tail -n "$max_lines"
    printf '%s\n' "---TRUNCATED_FROM:${total_lines}---"
  else
    printf '%s' "$input"
  fi
}

# Parse truncation sentinel from truncate_test_output result.
# Returns 0 and echoes total lines if truncated, returns 1 if not.
_parse_truncation_sentinel() {
  local text="$1"
  local last_line
  last_line="$(printf '%s\n' "$text" | tail -n 1)"
  if [[ "$last_line" =~ ^---TRUNCATED_FROM:([0-9]+)---$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Strip the truncation sentinel line from truncated output.
_strip_truncation_sentinel() {
  local text="$1"
  printf '%s\n' "$text" | sed '$d'
}

# Read per-task test output, truncated to AUTOPILOT_MAX_TEST_OUTPUT lines.
read_task_test_output() {
  local project_dir="${1:-.}"
  local task_number="$2"
  _validate_test_output_task_number "$task_number" "$project_dir" || return 1
  local max_lines="${AUTOPILOT_MAX_TEST_OUTPUT:-500}"
  local output_file
  output_file="$(_task_test_output_path "$project_dir" "$task_number")"

  [[ -f "$output_file" ]] || return 0

  local raw_content
  raw_content="$(cat "$output_file")"
  local result
  result="$(truncate_test_output "$raw_content" "$max_lines")"

  local original_lines
  if original_lines="$(_parse_truncation_sentinel "$result")"; then
    log_msg "$project_dir" "WARNING" \
      "Test output truncated: ${original_lines} lines exceeds limit of ${max_lines}"
    result="$(_strip_truncation_sentinel "$result")"
  fi

  printf '%s' "$result"
}
