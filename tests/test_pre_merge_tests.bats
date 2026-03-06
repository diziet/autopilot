#!/usr/bin/env bats
# Tests for _run_pre_merge_tests in lib/dispatch-handlers.sh.
# Validates SHA-based skip logic: when the fixer's post-fix verification
# already passed at the current HEAD, the pre-merge test run is skipped.

load helpers/dispatcher_setup

# --- Helper: write verified SHA flag matching HEAD ---

_set_verified_sha() {
  local sha
  sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$sha"
}

# --- _run_pre_merge_tests: SHA matches → skip tests ---

@test "pre-merge tests: SHA matches HEAD skips test run" {
  _set_verified_sha

  # Mock run_test_gate to fail if called (should NOT be called).
  run_test_gate() { echo "SHOULD NOT RUN" >&2; return 99; }
  export -f run_test_gate

  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1

  # Verify the skip was logged.
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Tests already verified at current SHA"* ]]
  [[ "$log" == *"skipping pre-merge test run"* ]]
}

@test "pre-merge tests: SHA matches HEAD returns 0 (proceed to merger)" {
  _set_verified_sha

  local exit_code=0
  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1 || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

# --- _run_pre_merge_tests: SHA doesn't match → run tests ---

@test "pre-merge tests: stale SHA runs test gate" {
  write_hook_sha_flag "$TEST_PROJECT_DIR" "stale_sha_that_doesnt_match"
  AUTOPILOT_TEST_CMD="true"

  local exit_code=0
  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1 || exit_code=$?
  [ "$exit_code" -eq 0 ]

  # Verify the "not verified" log message appeared.
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"SHA not verified"* ]]
  [[ "$log" == *"running pre-merge test gate"* ]]
}

@test "pre-merge tests: mismatched SHA runs tests and proceeds on pass" {
  write_hook_sha_flag "$TEST_PROJECT_DIR" "old_sha_different_from_head"
  AUTOPILOT_TEST_CMD="true"

  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

# --- _run_pre_merge_tests: no SHA flag → run tests ---

@test "pre-merge tests: no SHA flag runs test gate" {
  # Ensure no flag file exists.
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  AUTOPILOT_TEST_CMD="true"

  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"SHA not verified"* ]]
}

@test "pre-merge tests: no SHA flag with no test cmd returns SKIP (proceed)" {
  clear_hook_sha_flag "$TEST_PROJECT_DIR"

  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

# --- _run_pre_merge_tests: test gate fails → test_fixing ---

@test "pre-merge tests: test failure transitions to test_fixing" {
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  _set_state "fixed"
  _set_task 1
  AUTOPILOT_TEST_CMD="false"

  run _run_pre_merge_tests "$TEST_PROJECT_DIR" 1
  [ "$status" -ne 0 ]

  [ "$(_get_status)" = "test_fixing" ]
}

@test "pre-merge tests: test failure logs warning" {
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  _set_state "fixed"
  _set_task 1
  AUTOPILOT_TEST_CMD="false"

  _run_pre_merge_tests "$TEST_PROJECT_DIR" 1 || true

  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Pre-merge tests failed"* ]]
  [[ "$log" == *"returning to test_fixing"* ]]
}

# --- _run_pre_merge_tests: test gate error → retry/diagnose ---

@test "pre-merge tests: test gate error triggers retry" {
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  _set_state "fixed"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  # Mock run_test_gate to return TESTGATE_ERROR.
  run_test_gate() { return "$TESTGATE_ERROR"; }
  export -f run_test_gate

  run _run_pre_merge_tests "$TEST_PROJECT_DIR" 1
  [ "$status" -ne 0 ]

  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixed integration: SHA verified → skip → merger runs ---

@test "fixed: SHA verified skips tests and proceeds to merger" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _set_verified_sha

  run_merger() { return 0; }
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]

  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Tests already verified at current SHA"* ]]
}

# --- _handle_fixed integration: SHA not verified → tests run ---

@test "fixed: no SHA flag runs tests then proceeds to merger" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  clear_hook_sha_flag "$TEST_PROJECT_DIR"

  run_merger() { return 0; }
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]

  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"SHA not verified"* ]]
}

@test "fixed: SHA mismatch runs tests, failure goes to test_fixing" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "wrong_sha"
  AUTOPILOT_TEST_CMD="false"

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]
}

@test "fixed: SHA mismatch runs tests, pass proceeds to merger" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "wrong_sha"
  AUTOPILOT_TEST_CMD="true"

  run_merger() { return 0; }
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}
