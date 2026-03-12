#!/usr/bin/env bats
# Tests for lib/spec-review-async.sh — Async spec review: PID file paths,
# background spawning, completion checking, and edge cases.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/spec-review.sh"
source "$BATS_TEST_DIRNAME/../lib/spec-review-async.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"
}

# Helper: set up files simulating a completed background spec review.
_setup_completed_review() {
  local exit_code="${1:-0}" task_number="${2:-99}"
  echo "999999 ${task_number}" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "$exit_code" > "$TEST_PROJECT_DIR/.autopilot/spec-review.exit"
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
  echo "$$ 5" > "$pid_file"

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
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local content pid
  content="$(cat "$pid_file" 2>/dev/null)" || true
  pid="${content%% *}"
  [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
}

# --- run_spec_review_async: spawns background process ---

@test "run_spec_review_async creates PID file with task number" {
  run_spec_review() { sleep 0.1; return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "1"
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local content pid
  content="$(cat "$pid_file")"
  # Format: "PID TASK_NUMBER"
  [[ "$content" =~ ^[0-9]+\ 1$ ]]
  pid="${content%% *}"

  # Clean up: wait for background process.
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async cleans up stale exit file" {
  local exit_file="$TEST_PROJECT_DIR/.autopilot/spec-review.exit"
  echo "1" > "$exit_file"

  run_spec_review() { sleep 0.1; return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "2"

  # Exit file should have been removed before spawning.
  [ ! -f "$exit_file" ]

  # Clean up.
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local content pid
  content="$(cat "$pid_file" 2>/dev/null)" || true
  pid="${content%% *}"
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async writes exit code on completion" {
  run_spec_review() { return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "4"

  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  local content pid
  content="$(cat "$pid_file")"
  pid="${content%% *}"

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
  local content pid
  content="$(cat "$pid_file")"
  pid="${content%% *}"
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
  echo "${bg_pid} 10" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "check_spec_review_completion returns 0 when process completed" {
  _setup_completed_review "0" "10"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # PID and exit files should be cleaned up.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.exit" ]
}

@test "check_spec_review_completion logs completion with exit code" {
  _setup_completed_review "1" "10"

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
  echo "999999 10" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  # No exit file — should default to exit code 0.

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # PID file should be cleaned up.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

# --- Integration: spawn and completion cycle ---

@test "async lifecycle: spawn, check running, complete, check done" {
  run_spec_review() { sleep 0.1; return 0; }

  # Spawn.
  run_spec_review_async "$TEST_PROJECT_DIR" "10"
  local pid_file="$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local content pid
  content="$(cat "$pid_file")"
  pid="${content%% *}"

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

# --- Stderr path with task number ---

@test "_spec_review_stderr_path includes task number" {
  local result
  result="$(_spec_review_stderr_path "$TEST_PROJECT_DIR" "42")"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-42.log" ]
}

@test "_spec_review_stderr_path falls back without task number" {
  local result
  result="$(_spec_review_stderr_path "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr.log" ]
}

# --- Stderr file creation ---

@test "run_spec_review_async creates task-specific stderr log file" {
  run_spec_review() { echo "some error" >&2; return 1; }

  run_spec_review_async "$TEST_PROJECT_DIR" "55"

  local content pid
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/spec-review.pid")"
  pid="${content%% *}"
  wait "$pid" 2>/dev/null || true

  local stderr_log="$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-55.log"
  [ -f "$stderr_log" ]
  [[ "$(cat "$stderr_log")" == *"some error"* ]]
}

@test "run_spec_review_async embeds task number in PID file" {
  run_spec_review() { return 0; }

  run_spec_review_async "$TEST_PROJECT_DIR" "77"

  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/spec-review.pid")"
  [[ "$content" =~ ^[0-9]+\ 77$ ]]

  local pid="${content%% *}"
  wait "$pid" 2>/dev/null || true
}

# --- Completion check logs stderr on failure ---

@test "check_spec_review_completion logs stderr as WARNING on non-zero exit" {
  _setup_completed_review "1" "33"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "Error: Claude API timeout" > \
    "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-33.log"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"WARNING"* ]]
  [[ "$log_content" == *"Claude API timeout"* ]]
}

@test "check_spec_review_completion logs stderr as DEBUG on success" {
  _setup_completed_review "0" "34"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "debug info only" > \
    "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-34.log"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"DEBUG"* ]] || [[ "$log_content" == *"debug info only"* ]]
}

@test "check_spec_review_completion removes fallback stderr log" {
  _setup_completed_review "0" "50"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "legacy" > "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr.log"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr.log" ]
}

@test "check_spec_review_completion validates task number from PID file" {
  # Malicious task number in PID file — should be ignored, not used in path.
  echo "999999 ../../etc/evil" > "$TEST_PROJECT_DIR/.autopilot/spec-review.pid"
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/spec-review.exit"

  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Should fall back to non-task-numbered path, not traverse.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/spec-review.pid" ]
}

# --- Old stderr log cleanup ---

@test "_cleanup_old_stderr_logs keeps 5 most recent files" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  # Create 7 stderr log files with staggered modification times.
  local i
  for i in 1 2 3 4 5 6 7; do
    echo "log $i" > "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-${i}.log"
    # Touch with increasing timestamps so ls -1t ordering is deterministic.
    touch -t "202601010000.0${i}" \
      "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-${i}.log"
  done

  _cleanup_old_stderr_logs "$TEST_PROJECT_DIR"

  # 5 newest (tasks 3-7) should remain, 2 oldest (tasks 1-2) removed.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-1.log" ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-2.log" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-3.log" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-7.log" ]
}

@test "_cleanup_old_stderr_logs does nothing with 5 or fewer files" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  local i
  for i in 1 2 3 4 5; do
    echo "log $i" > "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-${i}.log"
  done

  _cleanup_old_stderr_logs "$TEST_PROJECT_DIR"

  # All 5 should remain.
  for i in 1 2 3 4 5; do
    [ -f "$TEST_PROJECT_DIR/.autopilot/logs/spec-review-stderr-task-${i}.log" ]
  done
}

@test "_cleanup_old_stderr_logs handles empty logs directory" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  run _cleanup_old_stderr_logs "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_cleanup_old_stderr_logs handles missing logs directory" {
  run _cleanup_old_stderr_logs "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}
