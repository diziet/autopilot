#!/usr/bin/env bats
# Tests for fixer fail-fast: skip postfix when fixer produces no commits.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# --- Shared setup ---

# Set up common state for fixer fail-fast tests.
_setup_fixer_failfast() {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5

  # Default mocks: fixer did not push, postfix/comment are no-ops.
  verify_fixer_push() { return 1; }
  post_fixer_result_comment() { return 0; }
  run_postfix_verification() {
    touch "$BATS_TEST_TMPDIR/postfix_called"
    return 1
  }
  # Mock _retry_or_diagnose to track calls without side effects.
  _retry_or_diagnose() {
    touch "$BATS_TEST_TMPDIR/retry_or_diagnose_called"
    update_status "$1" "pending"
  }
  export -f verify_fixer_push post_fixer_result_comment
  export -f run_postfix_verification _retry_or_diagnose
}

# --- Fail-fast: no commits + non-zero exit ---

@test "fixer failfast: no commits and non-zero exit skips postfix" {
  _setup_fixer_failfast

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  # Postfix should NOT have been called.
  [ ! -f "$BATS_TEST_TMPDIR/postfix_called" ]
  # _retry_or_diagnose should have been called.
  [ -f "$BATS_TEST_TMPDIR/retry_or_diagnose_called" ]
}

@test "fixer failfast: uses main retry budget not test_fix_retries" {
  _setup_fixer_failfast

  # Override _retry_or_diagnose to NOT reset test_fix_retries (so we can
  # verify the fail-fast path itself doesn't increment it).
  _retry_or_diagnose() { update_status "$1" "pending"; }
  export -f _retry_or_diagnose

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  # test_fix_retries should NOT have been incremented.
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "fixer failfast: fixer result comment still posted" {
  _setup_fixer_failfast

  # Track whether comment was posted.
  post_fixer_result_comment() { touch "$BATS_TEST_TMPDIR/comment_posted"; }
  export -f post_fixer_result_comment

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 1

  [ -f "$BATS_TEST_TMPDIR/comment_posted" ]
}

# --- Normal path: fixer with commits still runs postfix ---

@test "fixer failfast: fixer with commits runs postfix normally" {
  _setup_fixer_failfast

  # Fixer pushed successfully.
  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 0

  [ "$(_get_status)" = "fixed" ]
}

@test "fixer failfast: no commits but zero exit still runs postfix" {
  _setup_fixer_failfast

  # Fixer did not push but exited cleanly.
  run_postfix_verification() { return 0; }
  export -f run_postfix_verification

  # Exit code 0 — fixer may have made non-push changes, run postfix.
  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42 0

  [ "$(_get_status)" = "fixed" ]
}
