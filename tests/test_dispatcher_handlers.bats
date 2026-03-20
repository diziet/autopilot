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
  _mock_ensure_pr_open
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
  # Still have main retries → increment and go to fixed (skip re-review).
  [ "$(_get_status)" = "fixed" ]
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

@test "fixing: second consecutive fixer crash falls back to fixed for merge verification" {
  _setup_fixing_state 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
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

# --- _ensure_pr_open return codes ---

@test "ensure_pr_open: returns 0 for OPEN PR" {
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "OPEN" "false"
  _restore_real_ensure_pr_open
  _ensure_pr_open "$TEST_PROJECT_DIR" "42"
}

@test "ensure_pr_open: returns 1 for MERGED PR" {
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "MERGED" "false"
  _restore_real_ensure_pr_open
  run _ensure_pr_open "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq 1 ]
}

@test "ensure_pr_open: returns 0 after successful reopen of CLOSED PR" {
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  gh() {
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh
  _restore_real_ensure_pr_open
  _ensure_pr_open "$TEST_PROJECT_DIR" "42"
}

@test "ensure_pr_open: returns 2 when reopen of CLOSED PR fails" {
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  gh() {
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh
  _restore_real_ensure_pr_open
  run _ensure_pr_open "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq 2 ]
}

# --- _handle_coder_result: PR state validation ---

@test "coder_result: merged PR advances to merged state" {
  # Need git repo for _handle_coder_result commit verification.
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "init" -q

  _set_state "implementing"
  _set_task 1
  _mock_pending_pipeline
  _setup_coder_commits 1
  _mock_metrics
  # Override detect_task_pr to find an existing PR.
  detect_task_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  # Mock _ensure_pr_open to return merged.
  _ensure_pr_open() { return 1; }
  export -f detect_task_pr _ensure_pr_open

  _handle_coder_result "$TEST_PROJECT_DIR" "1" "0"
  [ "$(_get_status)" = "merged" ]
}

@test "coder_result: closed PR creates new PR and continues" {
  # Need git repo for _handle_coder_result commit verification.
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "init" -q

  _set_state "implementing"
  _set_task 1
  _mock_pending_pipeline
  _setup_coder_commits 1
  # Override detect_task_pr to find an existing PR.
  detect_task_pr() { echo "https://github.com/testowner/testrepo/pull/76"; }
  # Mock _ensure_pr_open to return reopen-failed.
  _ensure_pr_open() { return 2; }
  # Mock _pipeline_push_and_create_pr to create a new PR.
  _pipeline_push_and_create_pr() {
    echo "https://github.com/testowner/testrepo/pull/99"
  }
  export -f detect_task_pr _ensure_pr_open _pipeline_push_and_create_pr

  _handle_coder_result "$TEST_PROJECT_DIR" "1" "0"
  [ "$(_get_status)" = "pr_open" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "99" ]
}

# --- _handle_pr_open: PR state validation ---

@test "pr_open: detects externally merged PR and advances to merged" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # Mock _ensure_pr_open to return merged.
  _ensure_pr_open() { return 1; }
  export -f _ensure_pr_open

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "pr_open: reopens closed PR and continues normally" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # Mock _ensure_pr_open to return open (successfully reopened).
  _ensure_pr_open() { return 0; }
  export -f _ensure_pr_open

  _handle_pr_open "$TEST_PROJECT_DIR"
  # Should stay in pr_open (no test gate result yet).
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: closed PR resets to pending" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # Mock _ensure_pr_open to return reopen-failed.
  _ensure_pr_open() { return 2; }
  export -f _ensure_pr_open

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "0" ]
}

# --- _handle_reviewed: PR state validation ---

@test "reviewed: merged PR advances to merged state" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_reviewed_json 42
  # Mock _ensure_pr_open to return merged.
  _ensure_pr_open() { return 1; }
  export -f _ensure_pr_open

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "reviewed: closed PR with branch creates new PR" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_reviewed_json 42
  # Mock _ensure_pr_open to return reopen-failed.
  _ensure_pr_open() { return 2; }
  # Mock fetch_remote_sha to indicate branch still exists.
  fetch_remote_sha() { echo "abc123"; }
  # Mock _pipeline_push_and_create_pr to create a new PR.
  _pipeline_push_and_create_pr() {
    echo "https://github.com/testowner/testrepo/pull/99"
  }
  _trigger_reviewer_background() { return 0; }
  export -f _ensure_pr_open fetch_remote_sha _pipeline_push_and_create_pr
  export -f _trigger_reviewer_background

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "99" ]
}

@test "reviewed: closed PR with no branch resets to pending" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_reviewed_json 42
  # Mock _ensure_pr_open to return reopen-failed.
  _ensure_pr_open() { return 2; }
  # Mock fetch_remote_sha to indicate branch is gone.
  fetch_remote_sha() { echo ""; }
  export -f _ensure_pr_open fetch_remote_sha

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "0" ]
}

# --- Draft PR auto-conversion ---

@test "ensure_pr_open: detects draft PR and converts to ready" {
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "OPEN" "true"
  _restore_real_ensure_pr_open
  # Mock _convert_draft_to_ready to track calls.
  local convert_called="false"
  _convert_draft_to_ready() { convert_called="true"; return 0; }
  export -f _convert_draft_to_ready
  _ensure_pr_open "$TEST_PROJECT_DIR" "42"
}

@test "merge_retry: draft error converts PR to ready and resets merge retries" {
  _setup_merge_retry_state 1
  # Write a "still a draft" error to the last_error file.
  echo "Pull Request is still a draft" > "$TEST_PROJECT_DIR/.autopilot/last_error"
  # Mock gh to succeed on pr ready.
  _mock_gh_merge_retry 0 "OPEN" "MERGEABLE"
  sleep() { return 0; }
  export -f sleep

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" "1" "42"

  # Merge retries should be reset (draft error doesn't count).
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(_get_status)" = "merging" ]
}

@test "merge_retry: draft error does not increment main retry counter" {
  _setup_merge_retry_state 2
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5
  # Write a "still a draft" error.
  echo "Pull Request is still a draft" > "$TEST_PROJECT_DIR/.autopilot/last_error"
  _mock_gh_merge_retry 0 "OPEN" "MERGEABLE"
  sleep() { return 0; }
  export -f sleep

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" "1" "42"

  # Main retry counter should remain at 0.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merge_retry: gh pr ready failure falls through to main retry budget" {
  _setup_merge_retry_state 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_MERGE_RETRIES=3
  # Write a "still a draft" error.
  echo "Pull Request is still a draft" > "$TEST_PROJECT_DIR/.autopilot/last_error"
  # Mock gh so pr ready fails but merge retry is exhausted.
  gh() {
    case "$*" in
      *"pr ready"*) return 1 ;;
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":true}' ;;
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *"pr view"*"--json mergeable"*) echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
      *"pr merge"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh
  get_repo_slug() { echo "testowner/testrepo"; }
  export -f get_repo_slug
  sleep() { return 0; }
  export -f sleep

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" "1" "42"

  # Merge retries exhausted → falls through to _retry_or_diagnose → increments main retry.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "mark_pr_ready_with_retry: succeeds on first attempt" {
  mark_pr_ready() { return 0; }
  export -f mark_pr_ready

  _mark_pr_ready_with_retry "$TEST_PROJECT_DIR" "42"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "mark_pr_ready_with_retry: retries once on failure then succeeds" {
  local attempt_file="${TEST_PROJECT_DIR}/mark_ready_attempts"
  echo "0" > "$attempt_file"
  export ATTEMPT_FILE="$attempt_file"
  mark_pr_ready() {
    local c; c="$(cat "$ATTEMPT_FILE")"; c=$((c + 1)); echo "$c" > "$ATTEMPT_FILE"
    [ "$c" -ge 2 ] && return 0 || return 1
  }
  export -f mark_pr_ready
  sleep() { return 0; }
  export -f sleep

  _mark_pr_ready_with_retry "$TEST_PROJECT_DIR" "42"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "mark_pr_ready_with_retry: logs ERROR after both attempts fail" {
  mark_pr_ready() { return 1; }
  export -f mark_pr_ready
  sleep() { return 0; }
  export -f sleep

  run _mark_pr_ready_with_retry "$TEST_PROJECT_DIR" "42"
  [ "$status" -ne 0 ]

  # Verify ERROR was logged.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "ERROR" "$log_file"
  grep -qF "Failed to convert draft PR #42 to ready after retry" "$log_file"
}
