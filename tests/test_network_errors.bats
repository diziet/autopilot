#!/usr/bin/env bats
# Tests for lib/network-errors.sh — network error detection and retry handling.
# Covers: _is_network_error pattern matching, network retry not incrementing
# normal retry count, network retries exhausted → pipeline paused,
# non-network error → retry incremented normally.

load helpers/dispatcher_setup

# --- _is_network_error pattern matching ---

@test "network: detects 'Could not resolve host' as network error" {
  run _is_network_error "fatal: unable to access 'https://github.com/foo/bar.git/': Could not resolve host: github.com"
  [ "$status" -eq 0 ]
}

@test "network: detects 'Connection refused' as network error" {
  run _is_network_error "Connection refused - connect(2) for 127.0.0.1 port 443"
  [ "$status" -eq 0 ]
}

@test "network: detects 'Connection timed out' as network error" {
  run _is_network_error "Connection timed out after 30001 milliseconds"
  [ "$status" -eq 0 ]
}

@test "network: detects 'Network is unreachable' as network error" {
  run _is_network_error "fatal: Network is unreachable"
  [ "$status" -eq 0 ]
}

@test "network: detects HTTP 503 as network error" {
  run _is_network_error "HTTP 503 Service Unavailable"
  [ "$status" -eq 0 ]
}

@test "network: detects 'Could not read from remote repository' as network error" {
  run _is_network_error "fatal: Could not read from remote repository. Please make sure you have the correct access rights."
  [ "$status" -eq 0 ]
}

@test "network: detects 'unable to access' as network error" {
  run _is_network_error "fatal: unable to access 'https://github.com/foo/bar.git/': Failed to connect to github.com port 443"
  [ "$status" -eq 0 ]
}

@test "network: detects 'connect ETIMEDOUT' as network error" {
  run _is_network_error "connect ETIMEDOUT 140.82.121.4:443"
  [ "$status" -eq 0 ]
}

@test "network: detects 'getaddrinfo ENOTFOUND' as network error" {
  run _is_network_error "getaddrinfo ENOTFOUND api.github.com"
  [ "$status" -eq 0 ]
}

@test "network: detects HTTP 502 as network error" {
  run _is_network_error "HTTP 502 Bad Gateway"
  [ "$status" -eq 0 ]
}

@test "network: does not flag normal coder exit as network error" {
  run _is_network_error "Coder exited with code 1 for task 5"
  [ "$status" -eq 1 ]
}

@test "network: does not flag test failure as network error" {
  run _is_network_error "Tests failed: 3 tests out of 50 failed"
  [ "$status" -eq 1 ]
}

@test "network: does not flag empty input as network error" {
  run _is_network_error ""
  [ "$status" -eq 1 ]
}

@test "network: detects 'socket hang up' as network error" {
  run _is_network_error "Error: socket hang up"
  [ "$status" -eq 0 ]
}

@test "network: detects 'No route to host' as network error" {
  run _is_network_error "connect: No route to host"
  [ "$status" -eq 0 ]
}

# --- _retry_or_diagnose with network errors ---

@test "network retry: network error does not increment retry count" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 2
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_NETWORK_RETRIES=20

  # Inject a network error into the pipeline log.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "Could not resolve host: github.com" \
    >> "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Retry count should NOT have been incremented (still 2).
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "2" ]
  # Network retry count should be incremented.
  [ "$(get_network_retries "$TEST_PROJECT_DIR")" = "1" ]
  # Should transition to pending for natural retry.
  [ "$(_get_status)" = "pending" ]
}

@test "network retry: non-network error increments retry count normally" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  # No network error in logs — just normal task failure.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "Coder exited with code 1 for task 1" \
    >> "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Normal retry count should be incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
  # Should transition to pending.
  [ "$(_get_status)" = "pending" ]
}

@test "network retry: exhausted network retries pauses pipeline" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_NETWORK_RETRIES=3
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 3

  # Inject a network error into the pipeline log.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "Connection refused" \
    >> "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # PAUSE file should be created.
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
  # Retry count should NOT have been incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "network retry: non-network error resets network retry counter" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  # No network error — just a normal task failure.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "Tests failed" \
    >> "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Network retry count should be reset to 0.
  [ "$(get_network_retries "$TEST_PROJECT_DIR")" = "0" ]
  # Normal retry should be incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "network retry: network error preserves retry count at max-1" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 4
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_NETWORK_RETRIES=20

  # Inject a network error.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "HTTP 503 Service Unavailable" \
    >> "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Retry count should still be 4 (not incremented to 5).
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "4" ]
  [ "$(_get_status)" = "pending" ]
}

# --- _get_recent_failure_output ---

@test "network: _get_recent_failure_output reads tail of pipeline log" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  # Overwrite the log file to start clean (setup may have added lines).
  : > "$log_file"
  local i
  for (( i=1; i<=30; i++ )); do
    echo "TESTLINE_$i" >> "$log_file"
  done

  local output
  output="$(_get_recent_failure_output "$TEST_PROJECT_DIR")"

  # Should contain the last line.
  echo "$output" | grep -q "TESTLINE_30"
  # Should not contain the first line (only last 20).
  ! echo "$output" | grep -q "TESTLINE_1$"
}

@test "network: _get_recent_failure_output handles missing log" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot/logs"
  run _get_recent_failure_output "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- Network retry counter functions ---

@test "network counter: get_network_retries defaults to 0" {
  local count
  count="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$count" = "0" ]
}

@test "network counter: increment_network_retries increases count" {
  increment_network_retries "$TEST_PROJECT_DIR"
  [ "$(get_network_retries "$TEST_PROJECT_DIR")" = "1" ]
  increment_network_retries "$TEST_PROJECT_DIR"
  [ "$(get_network_retries "$TEST_PROJECT_DIR")" = "2" ]
}

@test "network counter: reset_network_retries zeroes count" {
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 10
  reset_network_retries "$TEST_PROJECT_DIR"
  [ "$(get_network_retries "$TEST_PROJECT_DIR")" = "0" ]
}
