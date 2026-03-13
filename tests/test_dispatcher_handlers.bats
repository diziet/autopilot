#!/usr/bin/env bats
# Tests for dispatcher state handlers — _handle_implementing, _handle_test_fixing,
# _handle_reviewed, _handle_fixed, _handle_merging, _handle_merged,
# _pull_main_after_merge, and _handle_completed.
# Split from test_dispatcher.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# Override setup to use nogit template (tests don't need git operations).
setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  AUTOPILOT_USE_WORKTREES="false"

  _create_tasks_file 3
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  _mock_gh
  _mock_claude
  _mock_timeout
}

# --- _handle_implementing (crash recovery) ---

@test "implementing: crash recovery returns to pending with retry increment" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  _handle_implementing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_test_fixing ---

@test "test_fixing: tests now pass transitions to pr_open" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  run_test_gate() { return 0; }
  _trigger_reviewer_background() { return 0; }
  export -f run_test_gate _trigger_reviewer_background

  _handle_test_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "test_fixing: exhausted test fix retries with max main retries triggers diagnosis" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5
  run_test_gate() { return 1; }
  run_diagnosis() { return 0; }
  export -f run_test_gate run_diagnosis

  _handle_test_fixing "$TEST_PROJECT_DIR"
  # Max retries exhausted → diagnosis runs → advances to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "test_fixing: exhausted test fix retries increments main retry" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5
  run_test_gate() { return 1; }
  export -f run_test_gate

  _handle_test_fixing "$TEST_PROJECT_DIR"
  # Still have main retries → increment and go to pending for fresh coder.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixing (fixer crash recovery) ---

@test "fixing: first fixer crash retries as fixer (state goes to reviewed)" {
  _setup_fixing_state 0

  # Write reviewed.json so _clear_reviewed_status has something to clear.
  _write_reviewed_json 42

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
  [ "$(get_fixer_retries "$TEST_PROJECT_DIR")" = "1" ]
}

@test "fixing: second consecutive fixer crash falls back to full coder (state goes to pending)" {
  _setup_fixing_state 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
  # Fixer retry counter should be reset after fallback.
  [ "$(get_fixer_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "fixing: fixer retry counter resets on successful fix" {
  _setup_fixing_state 1
  _set_state "reviewed"

  # Write reviewed.json with issues so fixer is spawned.
  _write_reviewed_json 42

  # Mock fixer success path.
  run_fixer() { echo "/dev/null"; return 0; }
  fetch_remote_sha() { echo "abc123"; }
  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f run_fixer fetch_remote_sha verify_fixer_push run_postfix_verification

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
  [ "$(get_fixer_retries "$TEST_PROJECT_DIR")" = "0" ]
}

# --- _handle_reviewed ---

@test "reviewed: clean reviews skip fixer, transition to fixed" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Write a reviewed.json where all reviews are clean.
  _write_reviewed_json 42 true

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "reviewed: issues found spawns fixer" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Write a reviewed.json with issues.
  _write_reviewed_json 42

  # Mock fixer and postfix.
  run_fixer() { echo "/dev/null"; return 0; }
  fetch_remote_sha() { echo "abc123"; }
  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f run_fixer fetch_remote_sha verify_fixer_push run_postfix_verification

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

# --- _handle_fixed ---

@test "fixed: transitions to merging and spawns merger" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock merger to approve.
  run_merger() { return 0; }  # MERGER_APPROVE=0
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "fixed: merger reject goes back to reviewed" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock merger to reject.
  run_merger() { return 1; }  # MERGER_REJECT=1
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
}

@test "fixed: merger error retries merge and stays in merging on failure" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "merge_retry_count" 0
  AUTOPILOT_MAX_MERGE_RETRIES=3
  AUTOPILOT_MERGE_RETRY_DELAY=0
  AUTOPILOT_MERGE_WAIT_TIMEOUT=0

  # Mock merger to error.
  run_merger() { return 2; }  # MERGER_ERROR=2
  export -f run_merger

  # Make merge retry fail too.
  _mock_gh_merge_retry 1 "OPEN" "MERGEABLE"

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merging" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_merging (crash recovery) ---

@test "merging: crash recovery with retries left goes to fixed" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_merging "$TEST_PROJECT_DIR"

  # Task 158: merging retries go to fixed (not pending) to avoid branch deletion.
  [ "$(_get_status)" = "fixed" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_merged ---

@test "merged: advances task counter" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"

  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]
  [ "$(_get_status)" = "pending" ]
}

@test "merged: resets retry, test_fix, and fixer counters" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 2
  write_state_num "$TEST_PROJECT_DIR" "fixer_retry_count" 1
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(get_fixer_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merged: last task transitions to completed" {
  _set_state "merged"
  _set_task 3  # 3 tasks in file, this is the last.
  write_state "$TEST_PROJECT_DIR" "pr_number" "99"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "completed" ]
}

# --- _pull_main_after_merge ---

@test "merged: pull failure is non-fatal" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_metrics

  # Remote is a non-functional URL, so pull will fail.
  # _pull_main_after_merge should log warning and return 0.
  _handle_merged "$TEST_PROJECT_DIR"

  # Despite pull failure, state should still advance normally.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "merged: last task does not attempt pull" {
  _set_state "merged"
  _set_task 3  # Last task — transitions to completed, not pending.
  write_state "$TEST_PROJECT_DIR" "pr_number" "99"
  _mock_metrics

  # Override _pull_main_after_merge to detect if it's called.
  _pull_main_after_merge() { echo "SHOULD_NOT_BE_CALLED"; return 1; }
  export -f _pull_main_after_merge

  _handle_merged "$TEST_PROJECT_DIR"

  # Should transition to completed without calling pull.
  [ "$(_get_status)" = "completed" ]
}

@test "pull_main_after_merge: checkout failure is non-fatal" {
  # Point to a nonexistent target branch to force checkout failure.
  AUTOPILOT_TARGET_BRANCH="nonexistent-branch"

  run _pull_main_after_merge "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "pull_main_after_merge: pull failure is non-fatal" {
  # Remote is non-functional URL — checkout works but pull fails.
  run _pull_main_after_merge "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- _handle_completed ---

@test "completed: stays completed when current_task exceeds total tasks" {
  _set_state "completed"
  _set_task 4  # 3 tasks in file, task 4 is beyond.
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "completed: transitions to pending when new tasks are added" {
  _set_state "completed"
  _set_task 3  # Was the last task, but now we add a 4th.
  # Add a 4th task to the tasks file.
  printf '## Task 4: New task\nDo new thing.\n\n' >> "$TEST_PROJECT_DIR/tasks.md"
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
}

@test "completed: stays completed when no tasks file exists" {
  _set_state "completed"
  _set_task 4
  rm -f "$TEST_PROJECT_DIR/tasks.md"
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "completed: stays completed when total unchanged (high-water mark)" {
  _set_state "completed"
  _set_task 4  # 3 tasks, task 4 is beyond.
  # Simulate a previous completed run that recorded the high-water mark.
  write_state_num "$TEST_PROJECT_DIR" "completed_at_total" 3
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "completed: resumes when total exceeds high-water mark" {
  _set_state "completed"
  _set_task 4  # Was beyond 3, but now we add tasks 4 and 5.
  write_state_num "$TEST_PROJECT_DIR" "completed_at_total" 3
  printf '## Task 4: New task\nDo thing 4.\n\n' >> "$TEST_PROJECT_DIR/tasks.md"
  printf '## Task 5: Another task\nDo thing 5.\n\n' >> "$TEST_PROJECT_DIR/tasks.md"
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
}

@test "completed: handles empty current_task gracefully" {
  _set_state "completed"
  write_state "$TEST_PROJECT_DIR" "current_task" ""
  _handle_completed "$TEST_PROJECT_DIR"
  # Should stay completed (not crash or spuriously transition).
  [ "$(_get_status)" = "completed" ]
}
