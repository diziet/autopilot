#!/usr/bin/env bats
# Tests for review entry — quick guards, cron mode, review cycle,
# state transitions, PR SHA helpers, cleanup, locks, exit codes,
# and multi-reviewer integration.
# Split from test_review_entry.bats for parallel execution.

load helpers/review_entry_setup

# --- Quick Guards (bin/autopilot-review) ---

@test "quick guard: PAUSE file causes immediate exit" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # State should be unchanged — no work was done.
  [ "$(_get_status)" = "pending" ]
}

@test "quick guard: exits when review lock held by live PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # State should be unchanged.
  [ "$(_get_status)" = "pending" ]
}

@test "quick guard: proceeds when review lock held by dead PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999" > "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  # Script should proceed past guard (dead PID) and run cron review.
  # State is pending, so cron review will skip — exits cleanly.
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "quick guard: no lock file allows entry" {
  rm -f "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  # Script should proceed, run cron review, skip (state is pending).
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- Cron Mode (_run_cron_review) ---

@test "cron: skips when state is pending" {
  _set_state "pending"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is implementing" {
  _set_state "implementing"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is completed" {
  _set_state "completed"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is reviewed" {
  _set_state "reviewed"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is fixing" {
  _set_state "fixing"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is merging" {
  _set_state "merging"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: errors when pr_open but no pr_number" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" ""
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "cron: errors when pr_open with pr_number 0" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "0"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "cron: runs review cycle when pr_open with valid PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Use a single-reviewer config for speed.
  AUTOPILOT_REVIEWERS="general"

  _run_cron_review "$TEST_PROJECT_DIR"
  # After review, state should transition to reviewed.
  [ "$(_get_status)" = "reviewed" ]
}

@test "cron: transitions to reviewed after successful review" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _run_cron_review "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
}

@test "cron: stays in pr_open when diff fetch fails" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "999"

  # Override function mock with script mock for different behavior.
  unset -f gh
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*"headRefOid"*) echo "abc123def" ;;
  *"pr view"*"headRefName"*) exit 1 ;;
  *"pr diff"*) exit 1 ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
  # State should remain pr_open for retry.
  [ "$(_get_status)" = "pr_open" ]
}

# --- Review Cycle (_execute_review_cycle) ---

@test "review cycle: fetches diff and runs reviewers" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_OK" ]
}

@test "review cycle: handles diff too large (exit 2)" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Override fetch_pr_diff to return exit 2 (diff too large).
  fetch_pr_diff() { return 2; }
  export -f fetch_pr_diff

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "review cycle: handles diff fetch failure (exit 1)" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  fetch_pr_diff() { return 1; }
  export -f fetch_pr_diff

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "review cycle: uses placeholder when head SHA unavailable" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  # Override function mock with script mock for different behavior.
  unset -f gh
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"headRefOid"*) exit 1 ;;
  *"headRefName"*) echo "autopilot/task-1" ;;
  *"pr diff"*) echo "+test change" ;;
  *"pr comment"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_OK" ]
}

@test "review cycle: cron mode transitions pr_open to reviewed" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$(_get_status)" = "reviewed" ]
}

@test "review cycle: standalone mode does not transition state" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

# --- State Transition Helpers ---

@test "transition: _transition_after_review in cron mode updates state" {
  _set_state "pr_open"
  _transition_after_review "$TEST_PROJECT_DIR" "cron"
  [ "$(_get_status)" = "reviewed" ]
}

@test "transition: _transition_after_review in standalone mode is no-op" {
  _set_state "pr_open"
  _transition_after_review "$TEST_PROJECT_DIR" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

@test "transition: _transition_on_error stays in pr_open for cron" {
  _set_state "pr_open"
  _transition_on_error "$TEST_PROJECT_DIR" "cron"
  [ "$(_get_status)" = "pr_open" ]
}

@test "transition: _transition_on_error is no-op for standalone" {
  _set_state "pr_open"
  _transition_on_error "$TEST_PROJECT_DIR" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

# --- PR SHA Helper ---

@test "get_pr_head_sha: returns SHA from gh API" {
  local sha
  sha="$(_get_pr_head_sha "$TEST_PROJECT_DIR" "42")"
  [ "$sha" = "abc123def456" ]
}

@test "get_pr_head_sha: returns empty on gh failure" {
  # Override function mock for failure behavior.
  gh() { return 1; }
  export -f gh

  local sha
  sha="$(_get_pr_head_sha "$TEST_PROJECT_DIR" "42" 2>/dev/null)" || true
  [ -z "$sha" ]
}

# --- Cleanup Helpers ---

@test "cleanup: _cleanup_diff_file removes existing file" {
  local tmp_file
  tmp_file="$BATS_TEST_TMPDIR/diff_file"
  echo "test" > "$tmp_file"
  _cleanup_diff_file "$tmp_file"
  [ ! -f "$tmp_file" ]
}

@test "cleanup: _cleanup_diff_file handles empty path gracefully" {
  _cleanup_diff_file ""
  # Should not error.
}

@test "cleanup: _cleanup_diff_file handles nonexistent file" {
  _cleanup_diff_file "/nonexistent/path/file.txt"
  # Should not error.
}

@test "cleanup: _cleanup_result_dir removes existing directory" {
  local tmp_dir
  tmp_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$tmp_dir"
  echo "test" > "${tmp_dir}/file.txt"
  _cleanup_result_dir "$tmp_dir"
  [ ! -d "$tmp_dir" ]
}

@test "cleanup: _cleanup_result_dir handles empty path gracefully" {
  _cleanup_result_dir ""
  # Should not error.
}

# --- Lock Integration ---

@test "lock: review lock uses separate name from pipeline lock" {
  # Acquire review lock.
  acquire_lock "$TEST_PROJECT_DIR" "review"
  # Pipeline lock should still be acquirable.
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  release_lock "$TEST_PROJECT_DIR" "review"
  release_lock "$TEST_PROJECT_DIR" "pipeline"
}

@test "lock: review lock prevents concurrent review" {
  acquire_lock "$TEST_PROJECT_DIR" "review"
  # Second acquire should fail.
  run acquire_lock "$TEST_PROJECT_DIR" "review"
  [ "$status" -ne 0 ]
  release_lock "$TEST_PROJECT_DIR" "review"
}

# --- Exit Code Constants ---

@test "exit codes: REVIEW_OK is 0" {
  [ "$REVIEW_OK" -eq 0 ]
}

@test "exit codes: REVIEW_SKIP is 1" {
  [ "$REVIEW_SKIP" -eq 1 ]
}

@test "exit codes: REVIEW_ERROR is 2" {
  [ "$REVIEW_ERROR" -eq 2 ]
}

# --- Multi-Reviewer Integration ---

@test "multi-reviewer: all clean reviews sets _ALL_REVIEWS_CLEAN" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general,dry"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$(_get_status)" = "reviewed" ]
  [ "$_ALL_REVIEWS_CLEAN" = "true" ]
}

@test "multi-reviewer: works with single reviewer" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$status" -eq "$REVIEW_OK" ]
}
