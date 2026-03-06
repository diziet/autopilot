#!/usr/bin/env bats
# Tests for concurrent background test gate and immediate reviewer trigger.
# Verifies: background test gate runs concurrently with reviewer,
# test gate failure after review still triggers test_fixing,
# test gate pass with clean reviews skips fixer, reviewer triggered
# immediately on pr_open, result file consumed after read, and
# TESTGATE_ERROR in result file treated as failure (not "still running").

load helpers/dispatcher_setup

# --- Background Test Gate Concurrency Tests ---

@test "coder result: background test gate runs concurrently — always pr_open" {
  _set_state "implementing"
  _set_task 1
  # Create a commit so the pipeline detects work done by coder.
  _setup_coder_commits 1

  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() {
    echo "bg_test_gate_called" > "$TEST_PROJECT_DIR/.autopilot/bg_called"
  }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Always transitions to pr_open (background test gate is async).
  [ "$(_get_status)" = "pr_open" ]

  # Verify background test gate was invoked.
  [ -f "$TEST_PROJECT_DIR/.autopilot/bg_called" ]
}

@test "coder result: reviewer triggered immediately on pr_open" {
  _set_state "implementing"
  _set_task 1
  # Create a commit so the pipeline detects work done by coder.
  _setup_coder_commits 1

  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { return 0; }
  # Track that reviewer was triggered.
  _trigger_reviewer_background() {
    echo "reviewer_triggered" > "$TEST_PROJECT_DIR/.autopilot/reviewer_flag"
  }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Reviewer should be triggered immediately.
  [ -f "$TEST_PROJECT_DIR/.autopilot/reviewer_flag" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/reviewer_flag")" = "reviewer_triggered" ]
}

# --- pr_open: Background Test Gate Result Handling ---

@test "pr_open: no result file stays in pr_open (test still running)" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate pass stays in pr_open for review" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate skip stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_SKIP"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate already verified stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_ALREADY_VERIFIED"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate failure transitions to test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]
}

@test "pr_open: result file consumed after read (no stale loop)" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # Result file should be consumed (deleted) after read.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result" ]
}

@test "pr_open: failure result file consumed to prevent stale loop" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]

  # Result file consumed so test_fixing → pr_open won't re-read stale FAIL.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result" ]
}

@test "pr_open: TESTGATE_ERROR in result file treated as failure (not running)" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # Simulate worktree creation failure writing ERROR to result file.
  _write_test_gate_result "$TESTGATE_ERROR"

  _handle_pr_open "$TEST_PROJECT_DIR"
  # ERROR in result file is a final result — transition to test_fixing.
  [ "$(_get_status)" = "test_fixing" ]
}

@test "pr_open: test gate failure after review still triggers test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Simulate: reviewer already posted results (reviewed.json exists).
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"abc","is_clean":false}}}
JSON

  # But background test gate failed.
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"

  # Test gate failure takes precedence — go fix tests first.
  [ "$(_get_status)" = "test_fixing" ]
}

# --- Independent Failure Handling ---

@test "test gate pass with clean reviews leads to fixed (skips fixer)" {
  # Step 1: Start in pr_open with passing test gate.
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # Step 2: Reviewer marks as reviewed with clean reviews.
  update_status "$TEST_PROJECT_DIR" "reviewed"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":true}}}
JSON

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "test gate fail returns to test_fixing even if reviews clean" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Clean reviews exist.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true}}}
JSON

  # But test gate failed.
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"
  # Test failure caught in pr_open, transitions to test_fixing.
  [ "$(_get_status)" = "test_fixing" ]
}

@test "pr_open to test_fixing is a valid state transition" {
  _set_state "pr_open"

  # Verify pr_open:test_fixing is in valid transitions.
  _is_valid_transition "pr_open" "test_fixing"
}

# --- Reviewer Trigger Tests ---

@test "reviewer trigger: called during coder result after pr_open transition" {
  _set_state "implementing"
  _set_task 1
  # Create a commit so the pipeline detects work done by coder.
  _setup_coder_commits 1

  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { return 0; }
  # Record ordering: reviewer trigger must happen after pr_open.
  _trigger_reviewer_background() {
    local status
    status="$(read_state "$TEST_PROJECT_DIR" "status")"
    echo "$status" > "$TEST_PROJECT_DIR/.autopilot/trigger_state"
  }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Reviewer trigger should see pr_open state (called after transition).
  [ -f "$TEST_PROJECT_DIR/.autopilot/trigger_state" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/trigger_state")" = "pr_open" ]
}

@test "reviewer trigger: re-triggered when test_fixing returns to pr_open" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock test gate to pass (tests fixed).
  run_test_gate() { return "$TESTGATE_PASS"; }
  _trigger_reviewer_background() {
    echo "reviewer_retriggered" > "$TEST_PROJECT_DIR/.autopilot/retrigger_flag"
  }
  export -f run_test_gate _trigger_reviewer_background

  _handle_test_fixing "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pr_open" ]
  # Reviewer should be re-triggered.
  [ -f "$TEST_PROJECT_DIR/.autopilot/retrigger_flag" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/retrigger_flag")" = "reviewer_retriggered" ]
}

# --- Dispatch tick integration with pr_open ---

@test "dispatch_tick: pr_open with failed test gate goes to test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_FAIL"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]
}

@test "dispatch_tick: pr_open with passing test gate stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "dispatch_tick: pr_open with no result stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}
