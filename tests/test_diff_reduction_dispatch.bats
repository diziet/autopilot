#!/usr/bin/env bats
# Tests for diff-reduction dispatch logic — _handle_fixed re-check after fixer.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# Override setup for diff-reduction-specific state.
setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  AUTOPILOT_USE_WORKTREES="false"

  _create_tasks_file 3
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  _mock_gh
  _mock_claude
  _mock_timeout

  # Mock functions needed by _handle_fixed.
  resolve_pre_merge_conflicts() { return 0; }
  is_sha_verified() { return 0; }
  run_merger() { return 0; }
  _trigger_reviewer_background() { return 0; }
  record_phase_transition() { return 0; }
  _create_pause_file() { touch "$1/.autopilot/PAUSE"; }
  export -f resolve_pre_merge_conflicts is_sha_verified run_merger
  export -f _trigger_reviewer_background record_phase_transition
  export -f _create_pause_file
}

# --- _is_diff_reduction_active ---

@test "diff reduction active: returns true when flag set" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "diff_reduction_active" "true"

  _is_diff_reduction_active "$TEST_PROJECT_DIR"
}

@test "diff reduction active: returns false when flag empty" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "diff_reduction_active" ""

  run _is_diff_reduction_active "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "diff reduction active: returns false when flag not set" {
  _set_state "fixed"
  _set_task 1

  run _is_diff_reduction_active "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

# --- _handle_fixed with diff_reduction_active ---

@test "fixed with diff reduction: diff now under limit transitions to pr_open" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "diff_reduction_active" "true"
  write_state_num "$TEST_PROJECT_DIR" "diff_reduction_retry_count" 1

  # Mock diff check to say diff is now under limit (returns 1 = not oversized).
  check_diff_still_oversized() { return 1; }
  export -f check_diff_still_oversized

  _handle_fixed "$TEST_PROJECT_DIR"

  # Should transition to pr_open for normal review.
  [ "$(_get_status)" = "pr_open" ]

  # Diff reduction state should be cleared.
  local active
  active="$(read_state "$TEST_PROJECT_DIR" "diff_reduction_active")"
  [ -z "$active" ]

  # Retry counter should be reset.
  local retries
  retries="$(get_diff_reduction_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 0 ]
}

@test "fixed with diff reduction: diff still oversized retries diff-reduction" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "diff_reduction_active" "true"
  write_state_num "$TEST_PROJECT_DIR" "diff_reduction_retry_count" 1
  AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES=3

  # Mock diff check to say diff is still oversized (returns 0 = oversized).
  check_diff_still_oversized() { return 0; }
  export -f check_diff_still_oversized

  _handle_fixed "$TEST_PROJECT_DIR"

  # Should go back to pr_open for another diff-reduction review.
  [ "$(_get_status)" = "pr_open" ]
}

@test "fixed with diff reduction: max retries exceeded pauses pipeline" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "diff_reduction_active" "true"
  write_state_num "$TEST_PROJECT_DIR" "diff_reduction_retry_count" 2
  AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES=2

  check_diff_still_oversized() { return 0; }
  export -f check_diff_still_oversized

  _handle_fixed "$TEST_PROJECT_DIR"

  # Should create pause file.
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]

  # Diff reduction active should be cleared.
  local active
  active="$(read_state "$TEST_PROJECT_DIR" "diff_reduction_active")"
  [ -z "$active" ]
}

@test "fixed without diff reduction: proceeds to normal merger flow" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # No diff_reduction_active flag — normal flow.
  _handle_fixed "$TEST_PROJECT_DIR"

  # Should proceed to merging (default mock has merger approve).
  local status
  status="$(_get_status)"
  # Status should be merged (mock merger returns APPROVE and mock gh returns MERGED).
  [ "$status" = "merged" ]
}
