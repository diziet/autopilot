#!/usr/bin/env bats
# Tests for lib/timer.sh — timer instrumentation helpers.

load helpers/test_template

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Source timer.sh (which also sources state.sh and config.sh).
  source "$BATS_TEST_DIRNAME/../lib/timer.sh"
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# --- _timer_start ---

@test "_timer_start sets _TIMER_EPOCH to current epoch" {
  _timer_start
  [ -n "$_TIMER_EPOCH" ]
  # Should be a valid number close to current time.
  local now
  now="$(date +%s)"
  local diff=$(( now - _TIMER_EPOCH ))
  [ "$diff" -ge 0 ]
  [ "$diff" -le 2 ]
}

@test "_timer_start overwrites previous value" {
  _TIMER_EPOCH="1234567890"
  _timer_start
  [ "$_TIMER_EPOCH" != "1234567890" ]
}

# --- _timer_log ---

@test "_timer_log produces greppable TIMER line in log" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "test_step"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "TIMER: test_step" "$log_file"
}

@test "_timer_log format matches TIMER: <label> (<N>s)" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "branch setup"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  local line
  line="$(grep 'TIMER:' "$log_file")"
  # Match pattern: TIMER: branch setup (Ns) where N is digits.
  [[ "$line" =~ TIMER:\ branch\ setup\ \([0-9]+s\) ]]
}

@test "_timer_log reports elapsed seconds" {
  # Manually set epoch to 2 seconds ago.
  _TIMER_EPOCH=$(( $(date +%s) - 2 ))
  _timer_log "$TEST_PROJECT_DIR" "slow_step"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  local line
  line="$(grep 'TIMER:' "$log_file")"
  # Should report at least 2 seconds.
  [[ "$line" =~ TIMER:\ slow_step\ \(([0-9]+)s\) ]]
  local elapsed="${BASH_REMATCH[1]}"
  [ "$elapsed" -ge 2 ]
}

@test "_timer_log resets epoch for next sub-step" {
  _timer_start
  local first_epoch="$_TIMER_EPOCH"
  sleep 1
  _timer_log "$TEST_PROJECT_DIR" "step_one"
  # After _timer_log, _TIMER_EPOCH should be strictly newer (sleep guarantees 1s+).
  [ "$_TIMER_EPOCH" -gt "$first_epoch" ]
}

@test "_timer_log without prior _timer_start logs warning" {
  _TIMER_EPOCH=""
  _timer_log "$TEST_PROJECT_DIR" "orphan_step"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "WARNING" "$log_file"
  grep -q "no start recorded" "$log_file"
}

@test "_timer_log uses INFO level for normal output" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "info_check"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  local timer_line
  timer_line="$(grep 'TIMER:' "$log_file")"
  [[ "$timer_line" == *"[INFO]"* ]]
}

@test "multiple _timer_log calls produce separate TIMER lines" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "step_a"
  _timer_log "$TEST_PROJECT_DIR" "step_b"
  _timer_log "$TEST_PROJECT_DIR" "step_c"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  local count
  count="$(grep -c 'TIMER:' "$log_file")"
  [ "$count" -eq 3 ]
}

@test "grep TIMER gives full sub-step breakdown" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "preflight"
  _timer_log "$TEST_PROJECT_DIR" "branch setup"
  _timer_log "$TEST_PROJECT_DIR" "coder spawn"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  # All three should be greppable.
  local lines
  lines="$(grep 'TIMER' "$log_file")"
  [[ "$lines" == *"preflight"* ]]
  [[ "$lines" == *"branch setup"* ]]
  [[ "$lines" == *"coder spawn"* ]]
}

@test "_timer_log reports 0s for immediate call after _timer_start" {
  _timer_start
  _timer_log "$TEST_PROJECT_DIR" "instant"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  local line
  line="$(grep 'TIMER:' "$log_file")"
  [[ "$line" =~ TIMER:\ instant\ \(([0-9]+)s\) ]]
  local elapsed="${BASH_REMATCH[1]}"
  [ "$elapsed" -le 1 ]
}
