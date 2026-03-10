#!/usr/bin/env bash
# Parse test output from various frameworks and produce a one-line summary.
# Supports bats TAP output, pytest output, and generic pass/fail detection.
# Detects timeout kills (exit code 124/137 from `timeout` command).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TEST_SUMMARY_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TEST_SUMMARY_LOADED=1

# Exit codes that indicate the process was killed by `timeout`.
readonly _TIMEOUT_EXIT_CODE=124
readonly _SIGNAL_KILL_EXIT_CODE=137

# --- Timeout Detection ---

# Check if an exit code indicates a timeout kill.
is_timeout_exit() {
  local exit_code="$1"
  [[ "$exit_code" =~ ^[0-9]+$ ]] || return 1
  [[ "$exit_code" -eq "$_TIMEOUT_EXIT_CODE" ]] || \
    [[ "$exit_code" -eq "$_SIGNAL_KILL_EXIT_CODE" ]]
}

# --- Framework-Specific Parsers ---

# Parse bats TAP output. Counts "ok" and "not ok" lines.
# Echoes "total passed failed" or empty string if no TAP lines found.
_parse_bats_tap() {
  local output="$1"
  local ok_count=0
  local not_ok_count=0
  local found=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^ok\ [0-9] ]]; then
      ok_count=$(( ok_count + 1 ))
      found=true
    elif [[ "$line" =~ ^not\ ok\ [0-9] ]]; then
      not_ok_count=$(( not_ok_count + 1 ))
      found=true
    fi
  done <<< "$output"

  if [[ "$found" == "true" ]]; then
    local total=$(( ok_count + not_ok_count ))
    echo "${total} ${ok_count} ${not_ok_count}"
  fi
}

# Parse pytest summary line (e.g., "=== 5 passed, 2 failed in 3.21s ===").
# Echoes "total passed failed" or empty string if no pytest summary found.
_parse_pytest() {
  local output="$1"
  local passed=0
  local failed=0
  local errors=0

  local summary_line
  summary_line="$(grep -E '=+.*passed|=+.*failed|=+.*error' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  # Extract passed count.
  if [[ "$summary_line" =~ ([0-9]+)\ passed ]]; then
    passed="${BASH_REMATCH[1]}"
  fi
  # Extract failed count.
  if [[ "$summary_line" =~ ([0-9]+)\ failed ]]; then
    failed="${BASH_REMATCH[1]}"
  fi
  # Extract error count (treat as failures).
  if [[ "$summary_line" =~ ([0-9]+)\ error ]]; then
    errors="${BASH_REMATCH[1]}"
  fi

  local total_failed=$(( failed + errors ))
  local total=$(( passed + total_failed ))
  [[ "$total" -eq 0 ]] && return 0

  echo "${total} ${passed} ${total_failed}"
}

# Parse pytest duration from summary line (e.g., "in 3.21s").
# Echoes seconds as integer or empty string.
_parse_pytest_duration() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E '=+.*in [0-9]' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  if [[ "$summary_line" =~ in\ ([0-9]+(\.[0-9]+)?)s ]]; then
    # Round to integer.
    printf '%.0f' "${BASH_REMATCH[1]}"
  fi
}

# --- Generic Summary Builder ---

# Build a test summary line from parsed results and timing info.
# Args: total passed failed duration_seconds exit_code timeout_seconds
# Echoes a formatted summary string.
format_test_summary() {
  local total="$1"
  local passed="$2"
  local failed="$3"
  local duration="${4:-}"
  local exit_code="${5:-0}"
  local timeout_seconds="${6:-}"

  # Timeout case: tests were killed before completing.
  if is_timeout_exit "$exit_code"; then
    local ran_count="$total"
    local timeout_display="${timeout_seconds:-unknown}"
    if [[ "$ran_count" -gt 0 ]]; then
      echo "Tests: ${ran_count} ran, killed by timeout after ${timeout_display}s"
    else
      echo "Tests: killed by timeout after ${timeout_display}s"
    fi
    return 0
  fi

  # Normal case: tests completed.
  local duration_str=""
  if [[ -n "$duration" ]] && [[ "$duration" != "0" ]]; then
    duration_str=" in ${duration}s"
  fi

  echo "Tests: ${total} total, ${passed} passed, ${failed} failed${duration_str}"
}

# --- Main Entry Point ---

# Parse test output and produce a one-line summary.
# Args: test_output exit_code timeout_seconds [duration_seconds]
# Echoes the summary line or empty string if output is unparseable.
parse_test_summary() {
  local output="$1"
  local exit_code="${2:-0}"
  local timeout_seconds="${3:-}"
  local duration="${4:-}"

  [[ -z "$output" ]] && return 0

  # Try bats TAP format first.
  local parsed
  parsed="$(_parse_bats_tap "$output")"
  if [[ -n "$parsed" ]]; then
    local total passed failed
    read -r total passed failed <<< "$parsed"
    format_test_summary "$total" "$passed" "$failed" \
      "$duration" "$exit_code" "$timeout_seconds"
    return 0
  fi

  # Try pytest format.
  parsed="$(_parse_pytest "$output")"
  if [[ -n "$parsed" ]]; then
    local total passed failed
    read -r total passed failed <<< "$parsed"
    # Use pytest's own duration if caller didn't provide one.
    if [[ -z "$duration" ]]; then
      duration="$(_parse_pytest_duration "$output")"
    fi
    format_test_summary "$total" "$passed" "$failed" \
      "$duration" "$exit_code" "$timeout_seconds"
    return 0
  fi

  # Timeout with no parseable output — still report the timeout.
  if is_timeout_exit "$exit_code"; then
    format_test_summary "0" "0" "0" \
      "$duration" "$exit_code" "$timeout_seconds"
    return 0
  fi

  # Output was non-empty but unparseable and not a timeout — no summary.
  return 0
}

# Log TIMER and TEST_GATE summary lines for a test suite run.
# Args: project_dir label raw_exit timeout_seconds output elapsed_seconds
log_test_timing_and_summary() {
  local project_dir="$1"
  local label="$2"
  local raw_exit="$3"
  local timeout_seconds="$4"
  local output="${5:-}"
  local elapsed="$6"

  # TIMER line (same format as timer_log in metrics.sh).
  log_msg "$project_dir" "INFO" "TIMER: ${label} (${elapsed}s)"

  # TEST_GATE summary line.
  local summary
  summary="$(parse_test_summary "$output" "$raw_exit" "$timeout_seconds" "$elapsed")"
  if [[ -n "$summary" ]]; then
    log_msg "$project_dir" "INFO" "TEST_GATE: ${summary}"
  fi
}
