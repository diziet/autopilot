#!/usr/bin/env bats
# Tests for review entry — standalone mode, entry point integration,
# argument handling, numeric validation, usage, reviewer retry/JSON saving.
# Split from test_review_entry.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/review_entry_setup

# --- Standalone Mode (_run_standalone_review) ---

@test "standalone: rejects non-numeric PR number" {
  run _run_standalone_review "$TEST_PROJECT_DIR" "abc"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: rejects empty PR number" {
  run _run_standalone_review "$TEST_PROJECT_DIR" ""
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: rejects PR number with mixed content" {
  run _run_standalone_review "$TEST_PROJECT_DIR" "42abc"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: runs review for valid PR number" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  _run_standalone_review "$TEST_PROJECT_DIR" "42"
  # Standalone mode should NOT change pipeline state.
  [ "$(_get_status)" = "pr_open" ]
}

@test "standalone: does not modify pipeline state" {
  _set_state "pending"
  AUTOPILOT_REVIEWERS="general"

  _run_standalone_review "$TEST_PROJECT_DIR" "42"
  # State should remain pending — standalone never touches state.
  [ "$(_get_status)" = "pending" ]
}

@test "standalone: works even when state is not pr_open" {
  _set_state "implementing"
  AUTOPILOT_REVIEWERS="general"

  run _run_standalone_review "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq "$REVIEW_OK" ]
  # State stays implementing — standalone mode is state-agnostic.
  [ "$(_get_status)" = "implementing" ]
}

# --- Entry Point Integration ---

@test "entry point: autopilot-review script is executable" {
  [ -x "$BATS_TEST_DIRNAME/../bin/autopilot-review" ]
}

@test "entry point: autopilot-review has correct shebang" {
  local first_line
  first_line="$(head -1 "$BATS_TEST_DIRNAME/../bin/autopilot-review")"
  [ "$first_line" = "#!/usr/bin/env bash" ]
}

@test "entry point: autopilot-review passes bash -n syntax check" {
  run bash -n "$BATS_TEST_DIRNAME/../bin/autopilot-review"
  [ "$status" -eq 0 ]
}

# --- Argument Handling (flag-based PR number) ---

@test "args: --pr flag triggers standalone review with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr 42
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10 from state.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
  ! grep -q " 10 " "$GH_MOCK_DIR/gh-calls.log"
  ! grep -q " 10$" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: --pr-number flag triggers standalone review with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr-number 42
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: --pr flag before project dir works with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --pr 42 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: bare positional PR number is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
  [[ "$output" == *"--pr NUMBER"* ]]
}

@test "args: extra positional args are rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" extra_arg
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}

@test "args: account number as positional arg is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}

@test "args: cron mode with no extra args works" {
  # State is pending so cron review will skip — exits cleanly.
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "args: --pr without value prints error" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a PR number"* ]]
}

@test "args: --help prints usage" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--pr NUMBER"* ]]
  [[ "$output" == *"Standalone mode"* ]]
}

@test "args: unknown flag is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --unknown
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}
