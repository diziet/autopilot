#!/usr/bin/env bats
# Tests for fixer fail-fast: skip postfix when fixer produces no commits.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# --- Fail-fast: no commits + non-zero exit ---

@test "fixer failfast: no commits and non-zero exit skips postfix" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  # Fixer did not push (SHA unchanged).
  verify_fixer_push() { return 1; }
  export -f verify_fixer_push

  # Track whether postfix was called.
  local postfix_called_file="$BATS_TEST_TMPDIR/postfix_called"
  run_postfix_verification() { touch "$postfix_called_file"; return 1; }
  export -f run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  # Postfix should NOT have been called.
  [ ! -f "$postfix_called_file" ]
  # State should go back to reviewed for next fixer attempt.
  [ "$(_get_status)" = "reviewed" ]
}

@test "fixer failfast: retry count increments on empty fixer" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  verify_fixer_push() { return 1; }
  export -f verify_fixer_push

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "1" ]
}

@test "fixer failfast: fixer result comment still posted" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  verify_fixer_push() { return 1; }
  export -f verify_fixer_push

  # Track whether comment was posted.
  local comment_file="$BATS_TEST_TMPDIR/comment_posted"
  post_fixer_result_comment() { touch "$comment_file"; }
  export -f post_fixer_result_comment

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  [ -f "$comment_file" ]
}

@test "fixer failfast: exhausted retries triggers diagnosis" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 2
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5

  verify_fixer_push() { return 1; }
  export -f verify_fixer_push

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  # Retry count was 2, incremented to 3 which equals max — triggers diagnosis.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- Normal path: fixer with commits still runs postfix ---

@test "fixer failfast: fixer with commits runs postfix normally" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"

  # Fixer pushed successfully.
  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 0

  [ "$(_get_status)" = "fixed" ]
}

@test "fixer failfast: no commits but zero exit still runs postfix" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"

  # Fixer did not push but exited cleanly.
  verify_fixer_push() { return 1; }
  run_postfix_verification() { return 0; }
  export -f verify_fixer_push run_postfix_verification

  # Exit code 0 — fixer may have made non-push changes, run postfix.
  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 0

  [ "$(_get_status)" = "fixed" ]
}
