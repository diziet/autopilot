#!/usr/bin/env bats
# Tests for dispatcher helpers, result handlers, retry logic,
# integration tests, PR merge verification, and worktree mode.
# Split from test_dispatcher.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# --- _extract_pr_number ---

@test "extract PR number from standard GitHub URL" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/42")"
  [ "$result" = "42" ]
}

@test "extract PR number from URL with trailing slash" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/123/")"
  [ "$result" = "123" ]
}

@test "extract PR number returns 0 on invalid URL" {
  run _extract_pr_number "not-a-url"
  [ "$output" = "0" ]
}

# --- _all_reviews_clean_from_json ---

@test "all_reviews_clean: true when all is_clean=true" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_10":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":true}}}
JSON
  _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when any is_clean=false" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_10":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":false}}}
JSON
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when no reviewed.json" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/reviewed.json"
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when PR key missing" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo '{"pr_99":{"general":{"sha":"a","is_clean":true}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

# --- _retry_or_diagnose ---

@test "retry: increments retry count and returns to pending" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "retry: max retries triggers diagnosis and advances task" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Should advance to task 2.
  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]
}

@test "retry: max retries on last task goes to pending (next tick completes)" {
  _set_state "implementing"
  _set_task 3  # last task
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _retry_or_diagnose "$TEST_PROJECT_DIR" 3 "implementing"

  # Advances to task 4 and goes to pending.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "4" ]
}

# --- _handle_merger_result ---

@test "merger result: APPROVE transitions to merged" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_APPROVE"
  [ "$(_get_status)" = "merged" ]
}

@test "merger result: REJECT goes to reviewed with hints" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_REJECT"
  [ "$(_get_status)" = "reviewed" ]
}

@test "merger result: ERROR retries merge and stays in merging on failure" {
  _setup_merge_retry_state
  _mock_gh_merge_retry 1 "OPEN" "MERGEABLE"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  [ "$(_get_status)" = "merging" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "1" ]
}

@test "merger result: ERROR merge retry succeeds on second attempt" {
  _setup_merge_retry_state
  _mock_gh_merge_retry 0 "MERGED" "MERGEABLE"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  [ "$(_get_status)" = "merged" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merger result: ERROR merge retries exhausted falls back to retry_or_diagnose" {
  _setup_merge_retry_state 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  # Task 158: falls back to _retry_or_diagnose which goes to fixed (not pending)
  # to avoid branch deletion that would close the PR.
  [ "$(_get_status)" = "fixed" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
  # merge_retry_count should be reset after falling back.
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merger result: ERROR reopens closed PR before retry" {
  _setup_merge_retry_state

  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
      *"pr view"*"--json state"*--jq*) echo "CLOSED" ;;
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 0 ;;
      *"pr merge"*) return 1 ;;
      *"pr view"*"--json mergeable"*) echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  # Verify gh pr reopen was called.
  grep -qF "pr reopen" "$gh_log"
}

@test "merger result: ERROR UNKNOWN mergeable status triggers polling" {
  _setup_merge_retry_state
  AUTOPILOT_MERGE_WAIT_TIMEOUT=1

  # First call returns UNKNOWN, second returns CLEAN.
  local call_count_file="${TEST_PROJECT_DIR}/mergeable_calls"
  echo "0" > "$call_count_file"
  export CALL_COUNT_FILE="$call_count_file"

  gh() {
    case "$*" in
      *"pr view"*"--json mergeable"*)
        local count
        count="$(cat "$CALL_COUNT_FILE")"
        count=$(( count + 1 ))
        echo "$count" > "$CALL_COUNT_FILE"
        if [[ "$count" -le 1 ]]; then
          echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
        else
          echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
        fi
        ;;
      *"pr view"*"--json state"*--jq*) echo "OPEN" ;;
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *"pr merge"*) return 0 ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"

  # Polling happened — more than one call to check mergeable.
  local final_count
  final_count="$(cat "$call_count_file")"
  [ "$final_count" -ge 2 ]
}

@test "merger result: ERROR already-merged PR short-circuits to merged" {
  _setup_merge_retry_state
  _mock_gh_merge_retry 1 "MERGED" "MERGEABLE"

  # Restore real _ensure_pr_open so merge retry can detect MERGED state.
  _restore_real_ensure_pr_open

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  [ "$(_get_status)" = "merged" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merger result: next tick continues merge retry instead of crash recovery" {
  _setup_merge_retry_state
  # Simulate first retry already happened (merge_retry_count=1).
  write_state_num "$TEST_PROJECT_DIR" "merge_retry_count" 1
  _mock_gh_merge_retry 0 "MERGED" "MERGEABLE"

  # _handle_merging should route to merge retry, not crash recovery.
  _handle_merging "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
}

# --- _handle_fixer_result ---

@test "fixer result: postfix pass transitions to fixed" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  [ "$(_get_status)" = "fixed" ]
}

@test "fixer result: postfix fail goes back to reviewed" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 1; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  [ "$(_get_status)" = "reviewed" ]
}

@test "fixer result: postfix fail with exhausted retries triggers diagnosis" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 1; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  # Exhausted test fix retries → _retry_or_diagnose increments main retry.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixing (crash recovery) ---

@test "fixing: first crash retries as fixer (goes to reviewed)" {
  _setup_fixing_state 0

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
  [ "$(get_fixer_retries "$TEST_PROJECT_DIR")" = "1" ]
}

@test "fixing: exhausted fixer retries falls back to pending" {
  _setup_fixing_state 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- MAX_RETRIES guard enforcement ---

@test "merger error: retry_count >= max triggers diagnosis and advances task" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  write_state_num "$TEST_PROJECT_DIR" "merge_retry_count" 3
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_MERGE_RETRIES=3
  AUTOPILOT_MERGE_RETRY_DELAY=0

  run_merger() { return 2; }  # MERGER_ERROR
  run_diagnosis() { return 0; }
  export -f run_merger run_diagnosis

  _handle_fixed "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "implementing crash recovery: retry_count >= max triggers diagnosis" {
  _set_state "implementing"
  _set_task 2
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_implementing "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 3.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "3" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "fixing crash recovery: retry_count >= max triggers diagnosis" {
  _setup_fixing_state 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_fixing "$TEST_PROJECT_DIR"

  # Fixer retries exhausted + main retries exhausted → diagnosis and advance.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merging crash recovery: retry_count >= max triggers diagnosis" {
  _set_state "merging"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_merging "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

# --- State machine integration ---

@test "full cycle: pending → implementing → pr_open (mocked)" {
  _set_state "pending"
  _set_task 1
  _mock_pending_pipeline

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "full cycle: reviewed → fixed (clean reviews)" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  _write_reviewed_json 42 true

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "full cycle: fixed → merged (merger approves)" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  run_merger() { return 0; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "full cycle: merged → pending (advance task)" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_metrics

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

# --- _verify_pr_merged ---

@test "verify_pr_merged: returns 0 when PR state is MERGED" {
  _mock_gh_pr_state "MERGED"
  _verify_pr_merged "$TEST_PROJECT_DIR" "42"
}

@test "verify_pr_merged: returns 1 when PR state is CLOSED" {
  _mock_gh_pr_state "CLOSED"
  ! _verify_pr_merged "$TEST_PROJECT_DIR" "42"
}

@test "verify_pr_merged: returns 1 when PR state is OPEN" {
  _mock_gh_pr_state "OPEN"
  ! _verify_pr_merged "$TEST_PROJECT_DIR" "42"
}

@test "verify_pr_merged: returns 1 when gh CLI fails (network error)" {
  _mock_gh_failure
  ! _verify_pr_merged "$TEST_PROJECT_DIR" "42"
}

@test "verify_pr_merged: returns 1 when gh returns empty state" {
  _mock_gh_pr_state ""
  ! _verify_pr_merged "$TEST_PROJECT_DIR" "42"
}

# --- PR merge verification in _handle_merger_result ---

@test "merger result: APPROVE with verified merge transitions to merged" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "MERGED"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_APPROVE"
  [ "$(_get_status)" = "merged" ]
}

@test "merger result: APPROVE but PR closed (not merged) resets to pending" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "CLOSED"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_APPROVE"
  # Should NOT advance to merged — resets to pending with same task.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
}

@test "merger result: APPROVE but gh API fails resets to pending (fail safe)" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_failure

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_APPROVE"
  # Fail safe: don't advance when verification fails.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
}

# --- PR merge verification in _handle_merged / _finalize_merged_task ---

@test "merged: PR verified as MERGED advances task normally" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "MERGED"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "merged: PR closed not merged resets to pending same task" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "CLOSED"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"
  # Should NOT advance — stays on task 1.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
}

@test "merged: PR still open does not advance" {
  _set_state "merged"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "55"
  _mock_gh_pr_state "OPEN"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"
  # Should NOT advance — stays on task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "merged: gh API failure does not advance (fail safe)" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_failure
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"
  # Fail safe: don't advance when gh CLI fails.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "1" ]
}

# --- Worktree-mode dispatcher tests ---

@test "worktree: pending tick creates worktree and coder runs inside it" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1
  _mock_pending_pipeline

  local test_dir="$TEST_PROJECT_DIR"
  local expected_wt="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"

  # Override run_coder to record worktree path and create commit there.
  run_coder() {
    local work_dir="${7:-$1}"
    echo "$work_dir" > "$test_dir/.autopilot/coder_work_dir"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  export -f run_coder

  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pr_open" ]
  # Worktree should exist after pending tick.
  [ -d "$expected_wt" ]
  # Coder should have been called with the worktree path.
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/coder_work_dir")" = "$expected_wt" ]
}

@test "worktree: merged tick cleans up worktree" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1

  # Create the worktree as _handle_pending would.
  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  [ -d "$worktree_path" ]

  # Simulate coder commit in the worktree.
  echo "change" >> "$worktree_path/testfile.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: implement task 1" -q

  # Now transition to merged and run the handler.
  _set_state "merged"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_metrics

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  # Worktree should be cleaned up after merge.
  [ ! -d "$worktree_path" ]
}
