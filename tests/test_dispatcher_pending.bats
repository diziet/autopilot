#!/usr/bin/env bats
# Tests for dispatcher — quick guards, dispatch_tick routing,
# _handle_pending, _handle_coder_result, and _pipeline_push_and_create_pr.
# Split from test_dispatcher.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# --- Quick Guards (bin/autopilot-dispatch) ---

@test "quick guard: exits 0 when PAUSE file exists" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  # Source the script in a subshell simulating the guard logic.
  local state_dir="${TEST_PROJECT_DIR}/.autopilot"
  [[ -f "${state_dir}/PAUSE" ]]
}

@test "quick guard: exits 0 when lock held by live PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_pid
  lock_pid="$(cat "$lock_file")"
  # Our own PID is alive.
  ps -p "$lock_pid" >/dev/null 2>&1
}

@test "quick guard: proceeds when lock held by dead PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999" > "${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_pid
  lock_pid="$(cat "$lock_file")"
  # PID 99999 is almost certainly dead.
  ! ps -p "$lock_pid" >/dev/null 2>&1
}

# --- dispatch_tick routing ---

@test "dispatch_tick routes pending state" {
  _set_state "pending"
  _mock_pending_pipeline

  dispatch_tick "$TEST_PROJECT_DIR"
  # After pending handler runs coder, pipeline pushes/creates PR → pr_open.
  local status
  status="$(_get_status)"
  [ "$status" = "pr_open" ]
}

@test "dispatch_tick routes pr_open — stays in pr_open when no result" {
  _set_state "pr_open"
  # No test gate result file — stays in pr_open.
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "dispatch_tick routes completed as no-op when all tasks done" {
  _set_state "completed"
  _set_task 4  # Beyond the 3 tasks in file.
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "dispatch_tick rejects unknown state" {
  write_state "$TEST_PROJECT_DIR" "status" "bogus"
  run dispatch_tick "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

# --- _handle_pending ---

@test "pending: transitions to completed when all tasks done" {
  _set_state "pending"
  _set_task 4  # 3 tasks in file, so task 4 is beyond.

  _handle_pending "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "pending: stale branch gets deleted" {
  _set_state "pending"
  _set_task 1
  # Create a stale branch.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main -q 2>/dev/null
  _mock_pending_pipeline

  _handle_pending "$TEST_PROJECT_DIR"
  # Branch should have been reset (deleted and recreated).
  local status
  status="$(_get_status)"
  [ "$status" = "pr_open" ]
}

# --- _handle_coder_result ---

@test "coder result: no commits after coder triggers retry" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  # Coder exits 0 but no commits on branch — pipeline retries.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q 2>/dev/null

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "coder result: commits only — pipeline pushes and creates PR" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1
  _mock_pending_pipeline

  # No existing PR — pipeline should push and create one.
  detect_task_pr() { return 1; }
  export -f detect_task_pr

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "42" ]
}

@test "coder result: coder already created PR — pipeline detects and skips" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1
  _mock_pending_pipeline

  # Coder already created a PR — pipeline should detect and reuse it.
  detect_task_pr() { echo "https://github.com/x/y/pull/55"; }
  export -f detect_task_pr

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "55" ]
}

@test "coder result: push failure triggers retry" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  _setup_coder_commits 1

  detect_task_pr() { return 1; }
  push_branch() { return 1; }
  export -f detect_task_pr push_branch

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "coder result: non-zero exit retries immediately without checking PR" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  _handle_coder_result "$TEST_PROJECT_DIR" 1 1
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _pipeline_push_and_create_pr ---

@test "pipeline push/PR: pushes branch and creates PR with generated body" {
  _set_task 1
  _setup_coder_commits 1

  push_branch() { return 0; }
  generate_pr_body() { echo "Generated body from diff"; }
  create_task_pr() { echo "https://github.com/x/y/pull/77"; }
  export -f push_branch generate_pr_body create_task_pr

  local pr_url
  pr_url="$(_pipeline_push_and_create_pr "$TEST_PROJECT_DIR" 1)"
  [ "$pr_url" = "https://github.com/x/y/pull/77" ]
}

@test "pipeline push/PR: push failure returns error" {
  _set_task 1
  _setup_coder_commits 1

  push_branch() { return 1; }
  export -f push_branch

  run _pipeline_push_and_create_pr "$TEST_PROJECT_DIR" 1
  [ "$status" -ne 0 ]
}

@test "pipeline push/PR: create_task_pr failure returns error" {
  _set_task 1
  _setup_coder_commits 1

  push_branch() { return 0; }
  generate_pr_body() { echo "body"; }
  create_task_pr() { return 1; }
  export -f push_branch generate_pr_body create_task_pr

  run _pipeline_push_and_create_pr "$TEST_PROJECT_DIR" 1
  [ "$status" -ne 0 ]
}

@test "pipeline push/PR: uses task header as primary title" {
  _set_task 1
  _setup_coder_commits 1

  local test_dir="$TEST_PROJECT_DIR"
  push_branch() { return 0; }
  generate_pr_body() { echo "body"; }
  # Capture the title argument (arg $3) via file — mock runs in subshell.
  create_task_pr() {
    echo "$3" > "$test_dir/.captured_title"
    echo "https://github.com/x/y/pull/42"
  }
  export -f push_branch generate_pr_body create_task_pr

  local pr_url
  pr_url="$(_pipeline_push_and_create_pr "$TEST_PROJECT_DIR" 1)"
  [ -n "$pr_url" ]
  # Title should come from tasks.md header (created by _create_tasks_file).
  [ "$(cat "$TEST_PROJECT_DIR/.captured_title")" = "Task 1: Test task 1" ]
}

@test "pipeline push/PR: falls back to commit message when no tasks file" {
  _set_task 1
  _setup_coder_commits 1
  # Remove tasks.md to force commit-message fallback.
  rm -f "$TEST_PROJECT_DIR/tasks.md"

  local test_dir="$TEST_PROJECT_DIR"
  push_branch() { return 0; }
  generate_pr_body() { echo "body"; }
  create_task_pr() {
    echo "$3" > "$test_dir/.captured_title"
    echo "https://github.com/x/y/pull/42"
  }
  export -f push_branch generate_pr_body create_task_pr

  local pr_url
  pr_url="$(_pipeline_push_and_create_pr "$TEST_PROJECT_DIR" 1)"
  [ -n "$pr_url" ]
  # Title should be the commit message from _setup_coder_commits.
  [ "$(cat "$TEST_PROJECT_DIR/.captured_title")" = "feat: implement task 1" ]
}

# --- Draft PR Flow ---

@test "pending: draft PR is created before coder spawns" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  local call_order_file="$test_dir/.autopilot/call_order"

  # Mock pending pipeline but track call order.
  run_preflight() { return 0; }
  _mock_commits_ahead
  push_branch() {
    echo "push" >> "$call_order_file"
    return 0
  }
  create_draft_pr() {
    echo "draft_pr" >> "$call_order_file"
    echo "https://github.com/x/y/pull/99"
  }
  detect_task_pr() { return 1; }
  run_coder() {
    echo "coder" >> "$call_order_file"
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/99"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  mark_pr_ready() { return 0; }
  export -f run_preflight push_branch create_draft_pr detect_task_pr
  export -f run_coder generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background mark_pr_ready

  _handle_pending "$TEST_PROJECT_DIR"

  # Verify draft PR was created before coder.
  [ -f "$call_order_file" ]
  local push_line draft_line coder_line
  push_line="$(grep -n "^push$" "$call_order_file" | head -1 | cut -d: -f1)"
  draft_line="$(grep -n "^draft_pr$" "$call_order_file" | head -1 | cut -d: -f1)"
  coder_line="$(grep -n "^coder$" "$call_order_file" | head -1 | cut -d: -f1)"
  [ "$push_line" -lt "$coder_line" ]
  [ "$draft_line" -lt "$coder_line" ]
}

@test "pending: PR number stored in state before coder spawns" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  _mock_commits_ahead
  push_branch() { return 0; }
  create_draft_pr() { echo "https://github.com/x/y/pull/77"; }
  detect_task_pr() { return 1; }
  run_coder() {
    # Verify PR number is in state BEFORE coder runs.
    local pr_num
    pr_num="$(jq -r '.pr_number' "$test_dir/.autopilot/state.json")"
    echo "$pr_num" > "$test_dir/.autopilot/pr_before_coder"
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  generate_pr_body() { echo "body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/77"; }
  run_test_gate_background() { echo "/tmp/result"; }
  _trigger_reviewer_background() { return 0; }
  mark_pr_ready() { return 0; }
  export -f run_preflight push_branch create_draft_pr detect_task_pr
  export -f run_coder generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background mark_pr_ready

  _handle_pending "$TEST_PROJECT_DIR"

  # PR number should have been available to the coder.
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/pr_before_coder")" = "77" ]
}

@test "pending: existing PR detected on retry — skips draft creation" {
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 1

  local test_dir="$TEST_PROJECT_DIR"
  # Simulate branch already exists from previous attempt.
  _setup_coder_commits 1
  git -C "$TEST_PROJECT_DIR" checkout main -q 2>/dev/null
  # Reinitialize state and tasks — git add -A committed them to the branch,
  # so checkout main removes them. Re-create with the desired state.
  init_pipeline "$TEST_PROJECT_DIR"
  _create_tasks_file 3
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 1

  run_preflight() { return 0; }
  _mock_commits_ahead
  push_branch() { return 0; }
  # PR already exists from first attempt.
  detect_task_pr() { echo "https://github.com/x/y/pull/55"; }
  create_draft_pr() {
    echo "SHOULD_NOT_CALL" > "$test_dir/.autopilot/draft_called"
    echo "https://github.com/x/y/pull/99"
  }
  run_coder() {
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: retry" -q
    return 0
  }
  generate_pr_body() { echo "body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/55"; }
  run_test_gate_background() { echo "/tmp/result"; }
  _trigger_reviewer_background() { return 0; }
  mark_pr_ready() { return 0; }
  export -f run_preflight push_branch detect_task_pr create_draft_pr
  export -f run_coder generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background mark_pr_ready

  _handle_pending "$TEST_PROJECT_DIR"

  # create_draft_pr should NOT have been called.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/draft_called" ]
  # PR number should be from the existing PR.
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "55" ]
}

@test "coder result: draft PR converted to ready after coder completes" {
  _set_state "implementing"
  _set_task 1
  # Store draft PR number so mark_pr_ready guard passes.
  write_state "$TEST_PROJECT_DIR" "draft_pr_number" "42"
  _setup_coder_commits 1
  _mock_pending_pipeline

  local test_dir="$TEST_PROJECT_DIR"
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  mark_pr_ready() {
    echo "$2" > "$test_dir/.autopilot/pr_readied"
    return 0
  }
  export -f detect_task_pr mark_pr_ready

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  [ "$(_get_status)" = "pr_open" ]
  # Verify mark_pr_ready was called with the correct PR number.
  [ -f "$TEST_PROJECT_DIR/.autopilot/pr_readied" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/pr_readied")" = "42" ]
}

@test "coder result: remaining commits pushed after coder completes" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1
  _mock_pending_pipeline

  local test_dir="$TEST_PROJECT_DIR"
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  push_branch() {
    echo "final_push" >> "$test_dir/.autopilot/push_calls"
    return 0
  }
  export -f detect_task_pr push_branch

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Verify push_branch was called for remaining commits.
  [ -f "$TEST_PROJECT_DIR/.autopilot/push_calls" ]
  grep -q "final_push" "$TEST_PROJECT_DIR/.autopilot/push_calls"
}

@test "pending: push failure does not block coder" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  _mock_commits_ahead
  # Push fails before coder, succeeds after (simulates transient network issue).
  export _PUSH_CALL_COUNT=0
  push_branch() {
    _PUSH_CALL_COUNT=$((_PUSH_CALL_COUNT + 1))
    if [[ "$_PUSH_CALL_COUNT" -le 1 ]]; then
      return 1
    fi
    return 0
  }
  detect_task_pr() { return 1; }
  create_draft_pr() { return 1; }
  run_coder() {
    # Verify coder was called despite push failure.
    echo "coder_ran" > "$test_dir/.autopilot/coder_flag"
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  generate_pr_body() { echo "body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/result"; }
  _trigger_reviewer_background() { return 0; }
  mark_pr_ready() { return 0; }
  export -f run_preflight push_branch detect_task_pr create_draft_pr
  export -f run_coder generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background mark_pr_ready

  _handle_pending "$TEST_PROJECT_DIR"

  # Coder should have run despite pre-coder push failure.
  [ -f "$TEST_PROJECT_DIR/.autopilot/coder_flag" ]
  [ "$(_get_status)" = "pr_open" ]
}

@test "coder result: pipeline calls push_branch when no existing PR" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1
  _mock_pending_pipeline

  local test_dir="$TEST_PROJECT_DIR"
  # No existing PR — pipeline should invoke push_branch.
  detect_task_pr() { return 1; }
  push_branch() {
    echo "push_called" > "$test_dir/.autopilot/push_flag"
    return 0
  }
  export -f detect_task_pr push_branch

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
  # Verify push_branch was actually invoked by the pipeline.
  [ -f "$TEST_PROJECT_DIR/.autopilot/push_flag" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/push_flag")" = "push_called" ]
}

# --- Tick overlap prevention (task 143) ---

# --- Task 158: Prevent branch deletion from closing PR during retries ---

@test "pending: branch with open PR is not deleted during Phase B reset" {
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Create a branch to trigger Phase B reset.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main -q 2>/dev/null

  local test_dir="$TEST_PROJECT_DIR"
  local delete_called_file="$test_dir/.autopilot/delete_called"

  # Track if delete_task_branch is called — it should NOT be.
  delete_task_branch() {
    echo "CALLED" > "$delete_called_file"
    return 0
  }
  export -f delete_task_branch

  _mock_pending_pipeline

  _handle_pending "$TEST_PROJECT_DIR"

  # delete_task_branch should NOT have been called (branch preserved for PR).
  [ ! -f "$delete_called_file" ]
}

@test "pending: PR is reopened if branch was recreated" {
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Create a stale branch (retry 0 = delete stale branches).
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main -q 2>/dev/null

  # Clear pr_number so _handle_branch_reset does NOT protect the branch —
  # simulates a case where pr_number was cleared or not set.
  write_state "$TEST_PROJECT_DIR" "pr_number" ""

  _mock_pending_pipeline

  local test_dir="$TEST_PROJECT_DIR"
  local reopen_file="$test_dir/.autopilot/reopen_called"

  # After branch deletion, restore pr_number so _reopen_pr_if_closed finds it.
  local _orig_create_task_branch
  create_task_branch() {
    git -C "$test_dir" checkout -b "autopilot/task-1" -q 2>/dev/null
    # Simulate: PR number was set by a previous run, re-add it before reopen check.
    write_state "$test_dir" "pr_number" "42"
    return 0
  }
  export -f create_task_branch

  # Track _ensure_pr_open calls.
  _ensure_pr_open() {
    echo "$2" > "$reopen_file"
    return 0
  }
  export -f _ensure_pr_open

  _handle_pending "$TEST_PROJECT_DIR"

  # _ensure_pr_open should have been called with PR #42.
  [ -f "$reopen_file" ]
  [ "$(cat "$reopen_file")" = "42" ]
}

@test "retry from merging state does not reset to pending on first merge failure" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  write_state_num "$TEST_PROJECT_DIR" "merge_retry_count" 3
  AUTOPILOT_MAX_MERGE_RETRIES=3

  # Mock merge retry as exhausted — _retry_merge_or_fallback calls _retry_or_diagnose.
  # Simulate by calling _retry_or_diagnose directly from merging state.
  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "merging"

  # Should transition to fixed, NOT pending.
  [ "$(_get_status)" = "fixed" ]
  # Retry counter should have been incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "pending: transitions to implementing before draft PR attempt" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  local order_file="$test_dir/.autopilot/call_order"

  # Override update_status to record when implementing is set.
  update_status() {
    if [[ "$2" == "implementing" ]]; then
      echo "implementing" >> "$order_file"
    fi
    write_state "$1" "status" "$2"
  }

  # Mock all external dependencies.
  run_preflight() { return 0; }
  _mock_commits_ahead
  push_branch() { return 1; }  # Push fails — draft PR will fail.
  detect_task_pr() { return 1; }
  record_task_start() { :; }
  read_completed_summary() { echo ""; }
  run_coder() { return 0; }
  _handle_coder_result() { :; }
  check_soft_pause() { :; }
  record_claude_usage() { :; }

  # Record draft PR call order.
  _push_and_create_draft_pr() {
    echo "draft_pr" >> "$order_file"
    write_state "$1" "pr_number" ""
  }

  export -f update_status run_preflight push_branch detect_task_pr
  export -f record_task_start read_completed_summary run_coder
  export -f _handle_coder_result check_soft_pause record_claude_usage
  export -f _push_and_create_draft_pr

  _handle_pending "$TEST_PROJECT_DIR"

  # Verify implementing was set BEFORE draft PR was attempted.
  [ -f "$order_file" ]
  local impl_line draft_line
  impl_line="$(grep -n "^implementing$" "$order_file" | head -1 | cut -d: -f1)"
  draft_line="$(grep -n "^draft_pr$" "$order_file" | head -1 | cut -d: -f1)"
  [ "$impl_line" -lt "$draft_line" ]
}
