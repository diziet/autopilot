#!/usr/bin/env bats
# Tests for lib/spec-review-async.sh — Async spec review: PID file paths,
# background spawning, completion checking, and edge cases.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/spec-review.sh"

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Source spec-review.sh first (defines constants), then async module.
  source "$BATS_TEST_DIRNAME/../lib/spec-review-async.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# --- PID file path helpers ---

@test "_spec_review_pid_file returns correct path" {
  local result
  result="$(_spec_review_pid_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

@test "_spec_review_pid_file defaults to current directory" {
  local result
  result="$(_spec_review_pid_file)"
  [ "$result" = "./.autopilot/spec-review.pid" ]
}

@test "_spec_review_exit_file returns correct path" {
  local result
  result="$(_spec_review_exit_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/spec-review.exit" ]
}

@test "_spec_review_exit_file defaults to current directory" {
  local result
  result="$(_spec_review_exit_file)"
  [ "$result" = "./.autopilot/spec-review.exit" ]
}

# --- run_spec_review_async: input validation ---

@test "run_spec_review_async rejects non-numeric task number" {
  run run_spec_review_async "$TEST_PROJECT_DIR" "abc"
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review_async rejects empty task number" {
  run run_spec_review_async "$TEST_PROJECT_DIR" ""
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review_async rejects task with special characters" {
  run run_spec_review_async "$TEST_PROJECT_DIR" "1;rm -rf /"
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

# --- run_spec_review_async: skips when already running ---

@test "run_spec_review_async skips when review already running" {
  # Create a PID file with our own PID (guaranteed to be alive).
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "$$" > "$pid_file"

  # Mock run_spec_review to fail (should not be called).
  run_spec_review() { return 99; }

  run run_spec_review_async "$TEST_PROJECT_DIR" "5"
  [ "$status" -eq 0 ]

  # Verify log mentions "already running".
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"already running"* ]]
}

@test "run_spec_review_async ignores stale PID file with dead process" {
  # Create PID file with a non-existent PID.
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "999999" > "$pid_file"

  # Mock run_spec_review to succeed quickly.
  run_spec_review() { return 0; }

  run run_spec_review_async "$TEST_PROJECT_DIR" "3"
  [ "$status" -eq 0 ]
  # Should have launched (log mentions "spawned").
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"spawned"* ]]

  # Wait for background process to finish.
  sleep 1
}

# --- run_spec_review_async: spawns background process ---

@test "run_spec_review_async creates PID file on success" {
  run_spec_review() { sleep 2; return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "1"
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local pid
  pid="$(cat "$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]]

  # Clean up: wait for background process.
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async cleans up stale exit file" {
  local exit_file="$TEST_PROJECT_DIR/.autopilot/spec-review.exit"
  echo "1" > "$exit_file"

  run_spec_review() { sleep 1; return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "2"

  # Exit file should have been removed before spawning.
  [ ! -f "$exit_file" ]

  # Clean up.
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local pid
  pid="$(cat "$pid_file" 2>/dev/null)" || true
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async writes exit code on completion" {
  run_spec_review() { return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "4"

  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local pid
  pid="$(cat "$pid_file")"

  # Wait for background process to complete.
  wait "$pid" 2>/dev/null || true

  local exit_file="$TEST_PROJECT_DIR/.autopilot/spec-review.exit"
  [ -f "$exit_file" ]
  local exit_code
  exit_code="$(cat "$exit_file")"
  [ "$exit_code" = "0" ]
}

@test "run_spec_review_async captures non-zero exit code" {
  run_spec_review() { return 2; }

  run_spec_review_async "$TEST_PROJECT_DIR" "7"

  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local pid
  pid="$(cat "$pid_file")"
  wait "$pid" 2>/dev/null || true

  local exit_file="$TEST_PROJECT_DIR/.autopilot/spec-review.exit"
  [ -f "$exit_file" ]
  local exit_code
  exit_code="$(cat "$exit_file")"
  [ "$exit_code" = "2" ]
}

# --- check_spec_review_completion ---

@test "check_spec_review_completion returns 0 when no PID file exists" {
  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "check_spec_review_completion returns 1 when process still running" {
  # Start a sleep process as our "background review".
  sleep 60 &
  local bg_pid=$!
  echo "$bg_pid" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "check_spec_review_completion returns 0 when process completed" {
  # Create PID file with a non-existent PID.
  echo "999999" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/spec-review.exit"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # PID and exit files should be cleaned up.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.exit" ]
}

@test "check_spec_review_completion logs completion with exit code" {
  echo "999999" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/spec-review.exit"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"completed"* ]]
  [[ "$log_content" == *"exit=1"* ]]
}

@test "check_spec_review_completion handles empty PID file" {
  echo "" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Empty PID file should be cleaned up.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

@test "check_spec_review_completion handles non-numeric PID file" {
  echo "not-a-pid" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

@test "check_spec_review_completion handles missing exit file gracefully" {
  # Process finished (dead PID) but no exit file.
  echo "999999" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  # No exit file — should default to exit code 0.

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # PID file should be cleaned up.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

# --- Integration: spawn and completion cycle ---

@test "async lifecycle: spawn, check running, complete, check done" {
  run_spec_review() { sleep 1; return 0; }

  # Spawn.
  run_spec_review_async "$TEST_PROJECT_DIR" "10"
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local pid
  pid="$(cat "$pid_file")"

  # Wait for completion.
  wait "$pid" 2>/dev/null || true
  sleep 0.2

  # Check completion.
  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Cleanup happened.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.exit" ]
}
