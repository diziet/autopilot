#!/usr/bin/env bats
# Tests for _handle_merged() finalize lock and status guard.
# Covers: concurrent tick simulation, lock prevents double-entry,
# lock released on error, and advance_task merged-status guard.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# Override setup to use nogit template (no tests here need git operations).
setup() {
  _init_test_from_template_nogit

  AUTOPILOT_USE_WORKTREES="false"

  # Create tasks file and CLAUDE.md.
  _create_tasks_file 3
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Mock external commands as shell functions.
  _mock_gh
  _mock_claude
  _mock_timeout
}

# --- Helper to mock all merged-state dependencies ---

# Set up standard mocks for _handle_merged dependencies.
_mock_merged_deps() {
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition
}

# --- Finalize lock acquisition ---

@test "merged: acquires finalize lock during execution" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Override _finalize_merged_task to check lock is held mid-execution.
  _finalize_merged_task() {
    local lock_file="${1}/.autopilot/locks/finalize.lock"
    if [ -f "$lock_file" ]; then
      touch "${1}/.autopilot/lock_was_held"
    fi
  }

  _handle_merged "$TEST_PROJECT_DIR"

  # Verify lock was held during finalization.
  [ -f "${TEST_PROJECT_DIR}/.autopilot/lock_was_held" ]
}

@test "merged: releases finalize lock after completion" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  _handle_merged "$TEST_PROJECT_DIR"

  # Lock should be released after handler completes.
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"
  [ ! -f "$lock_file" ]
}

# --- Lock prevents double-entry ---

@test "merged: second tick blocked when finalize lock held" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  # Pre-create finalize lock owned by a different (live) PID.
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  # Use PID 1 (launchd/init — always alive) to simulate another process.
  echo "1" > "${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"

  _handle_merged "$TEST_PROJECT_DIR"

  # Status should NOT have changed — handler returned early.
  [ "$(_get_status)" = "merged" ]
  # Task should NOT have advanced.
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
}

@test "merged: warning logged when finalize lock blocks entry" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  # Pre-create finalize lock owned by a live PID.
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "1" > "${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"

  _handle_merged "$TEST_PROJECT_DIR"

  # Check that the warning was logged.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -q "Finalize lock held by another tick" "$log_file"
}

# --- Concurrent tick simulation (status already changed) ---

@test "merged: second tick sees status already changed after lock release" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  # First tick runs normally.
  _handle_merged "$TEST_PROJECT_DIR"

  # After first tick: status=pending, task=2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]

  # Second tick calls _handle_merged but status is now "pending"
  # (the first tick already advanced). The post-lock guard should catch it.
  _set_state "pending"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 2

  # Call _handle_merged with status=pending — the guard should catch it.
  _handle_merged "$TEST_PROJECT_DIR"

  # Task should NOT have advanced further.
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(_get_status)" = "pending" ]
}

@test "merged: status guard prevents advance when status changed mid-execution" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock deps but have generate_task_summary_bg change status to "pending"
  # simulating another process advancing the task.
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() {
    # Simulate another tick changing status during summary generation.
    write_state "$1" "status" "pending"
  }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  # _advance_task should have detected status != merged and aborted.
  # Task should NOT have been incremented.
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]

  # Check warning was logged.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -q "advance_task: status is pending, not merged" "$log_file"
}

# --- Lock released on error ---

@test "merged: finalize lock released when metrics recording fails" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Make record_task_complete fail (non-fatal — handler continues).
  record_task_complete() { return 1; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  # Lock should be released even though record_task_complete failed.
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"
  [ ! -f "$lock_file" ]

  # Handler should still complete (metrics failure is non-fatal).
  [ "$(_get_status)" = "pending" ]
}

@test "merged: finalize lock released even when _finalize_merged_task errors" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Override _finalize_merged_task to simulate an error during finalization.
  _finalize_merged_task() { return 1; }

  # _handle_merged captures the error and still releases the lock.
  run _handle_merged "$TEST_PROJECT_DIR"

  # Error should propagate as the return code.
  [ "$status" -eq 1 ]

  # Lock should be released despite the error.
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"
  [ ! -f "$lock_file" ]
}

# --- _advance_task guard ---

@test "advance_task: only advances from merged status" {
  _set_state "merged"
  _set_task 1
  _mock_merged_deps

  _advance_task "$TEST_PROJECT_DIR" 1

  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(_get_status)" = "pending" ]
}

@test "advance_task: refuses to advance from non-merged status" {
  _set_state "pending"
  _set_task 1

  _advance_task "$TEST_PROJECT_DIR" 1

  # Task should NOT have been incremented.
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
  # Status unchanged.
  [ "$(_get_status)" = "pending" ]
}

@test "advance_task: logs warning when status is not merged" {
  _set_state "pending"
  _set_task 1

  _advance_task "$TEST_PROJECT_DIR" 1

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -q "advance_task: status is pending, not merged" "$log_file"
}

# --- Stale finalize lock recovery ---

@test "merged: stale finalize lock from dead PID is recovered" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  # Create a finalize lock with a dead PID.
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999" > "${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"

  _handle_merged "$TEST_PROJECT_DIR"

  # Should have recovered the stale lock and proceeded.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]

  # Lock should be released after completion.
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock"
  [ ! -f "$lock_file" ]
}

# --- dispatch_tick integration with finalize lock ---

@test "full cycle: merged with finalize lock still advances correctly" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_merged_deps

  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  # Lock released after tick.
  [ ! -f "${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock" ]
}

@test "full cycle: merged last task with finalize lock transitions to completed" {
  _set_state "merged"
  _set_task 3
  write_state "$TEST_PROJECT_DIR" "pr_number" "99"
  _mock_merged_deps

  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "completed" ]
  [ ! -f "${TEST_PROJECT_DIR}/.autopilot/locks/finalize.lock" ]
}
