#!/usr/bin/env bash
# Parse test output from various frameworks and produce a one-line summary.
# Orchestrates framework-specific parsers from lib/test-parsers.sh.
# Detects timeout kills (exit code 124/137 from `timeout` command).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TEST_SUMMARY_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TEST_SUMMARY_LOADED=1

# shellcheck source=lib/test-parsers.sh
source "${BASH_SOURCE[0]%/*}/test-parsers.sh"

# Exit codes that indicate the process was killed by `timeout`.
readonly _TIMEOUT_EXIT_CODE=124
readonly _SIGNAL_KILL_EXIT_CODE=137

# Order to try all parsers when framework is unknown.
readonly _ALL_FRAMEWORKS="bats pytest jest rspec go cargo junit"

# --- Timeout Detection ---

# Check if an exit code indicates a timeout kill.
is_timeout_exit() {
  local exit_code="$1"
  [[ "$exit_code" =~ ^[0-9]+$ ]] || return 1
  [[ "$exit_code" -eq "$_TIMEOUT_EXIT_CODE" ]] || \
    [[ "$exit_code" -eq "$_SIGNAL_KILL_EXIT_CODE" ]]
}

# --- Framework Detection from Command ---

# Map a test command to a framework name for parser selection.
_detect_framework_from_cmd() {
  local test_cmd="$1"
  case "$test_cmd" in
    bats\ *|bats)           echo "bats" ;;
    pytest\ *|pytest)       echo "pytest" ;;
    *jest\ *|*jest|*vitest\ *|*vitest) echo "jest" ;;
    *rspec\ *|*rspec)       echo "rspec" ;;
    cargo\ test*|*cargo\ test*) echo "cargo" ;;
    go\ test*|*\ go\ test*)    echo "go" ;;
    *gradlew\ test*|mvn\ test*|*mvn\ test*) echo "junit" ;;
    npm\ test*)              echo "" ;;
    *)                       echo "" ;;
  esac
}

# --- Parser Dispatch ---

# Try a specific parser by framework name. Echoes "total passed failed" or empty.
_try_parser() {
  local framework="$1"
  local output="$2"
  case "$framework" in
    bats)   _parse_bats_tap "$output" ;;
    pytest) _parse_pytest "$output" ;;
    jest)   _parse_jest "$output" ;;
    rspec)  _parse_rspec "$output" ;;
    go)     _parse_go_test "$output" ;;
    cargo)  _parse_cargo_test "$output" ;;
    junit)  _parse_junit "$output" ;;
    *)      return 0 ;;
  esac
}

# Extract framework-specific duration. Echoes seconds or empty.
_try_duration_parser() {
  local framework="$1"
  local output="$2"
  case "$framework" in
    pytest) _parse_pytest_duration "$output" ;;
    jest)   _parse_jest_duration "$output" ;;
    rspec)  _parse_rspec_duration "$output" ;;
    go)     _parse_go_test_duration "$output" ;;
    cargo)  _parse_cargo_test_duration "$output" ;;
    *)      return 0 ;;
  esac
}

# --- Generic Summary Builder ---

# Build a test summary line from parsed results and timing info.
# Args: total passed failed duration_seconds exit_code timeout_seconds
format_test_summary() {
  local total="$1"
  local passed="$2"
  local failed="$3"
  local duration="${4:-}"
  local exit_code="${5:-0}"
  local timeout_seconds="${6:-}"

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

  local duration_str=""
  if [[ -n "$duration" ]] && [[ "$duration" != "0" ]]; then
    duration_str=" in ${duration}s"
  fi

  echo "Tests: ${total} total, ${passed} passed, ${failed} failed${duration_str}"
}

# --- Test Count Extraction ---

# Extract total and passed counts from test output. Echoes "total passed".
_extract_test_counts() {
  local output="$1"
  [[ -z "$output" ]] && { echo "0 0"; return; }

  local parsed="" fw
  for fw in $_ALL_FRAMEWORKS; do
    parsed="$(_try_parser "$fw" "$output")"
    if [[ -n "$parsed" ]]; then
      local total passed _failed
      read -r total passed _failed <<< "$parsed"
      echo "$total $passed"
      return
    fi
  done

  echo "0 0"
}

# --- Main Entry Point ---

# Parse test output and produce a one-line summary.
# Args: test_output exit_code timeout_seconds [duration_seconds] [test_cmd]
parse_test_summary() {
  local output="$1"
  local exit_code="${2:-0}"
  local timeout_seconds="${3:-}"
  local duration="${4:-}"
  local test_cmd="${5:-}"

  [[ -z "$output" ]] && return 0

  # Determine which framework to try based on test command.
  local framework=""
  if [[ -n "$test_cmd" ]]; then
    framework="$(_detect_framework_from_cmd "$test_cmd")"
  fi

  local parsed=""
  if [[ -n "$framework" ]]; then
    parsed="$(_try_parser "$framework" "$output")"
  fi

  # If no result yet, try all parsers in order.
  if [[ -z "$parsed" ]]; then
    local fw
    for fw in $_ALL_FRAMEWORKS; do
      parsed="$(_try_parser "$fw" "$output")"
      if [[ -n "$parsed" ]]; then
        framework="$fw"
        break
      fi
    done
  fi

  if [[ -n "$parsed" ]]; then
    local total passed failed
    read -r total passed failed <<< "$parsed"
    if [[ -z "$duration" ]]; then
      duration="$(_try_duration_parser "$framework" "$output")"
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

  # Unparseable non-timeout output — return empty to preserve caller contract.
  return 0
}

# Log TIMER and TEST_GATE summary lines for a test suite run.
# Args: project_dir label raw_exit timeout_seconds output elapsed_seconds [test_cmd]
log_test_timing_and_summary() {
  local project_dir="$1"
  local label="$2"
  local raw_exit="$3"
  local timeout_seconds="$4"
  local output="${5:-}"
  local elapsed="$6"
  local test_cmd="${7:-}"

  log_msg "$project_dir" "INFO" "TIMER: ${label} (${elapsed}s)"

  local summary
  summary="$(parse_test_summary "$output" "$raw_exit" "$timeout_seconds" "$elapsed" "$test_cmd")"
  if [[ -n "$summary" ]]; then
    log_msg "$project_dir" "INFO" "TEST_GATE: ${summary}"
  fi
}
