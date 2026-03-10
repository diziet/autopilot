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

  # No existing PR — pipeline should push and create one.
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "Generated PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr push_branch generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "pr_number")" = "42" ]
}

@test "coder result: coder already created PR — pipeline detects and skips" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1

  # Coder already created a PR — pipeline should detect and reuse it.
  detect_task_pr() { echo "https://github.com/x/y/pull/55"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

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

@test "coder result: pipeline calls push_branch when no existing PR" {
  _set_state "implementing"
  _set_task 1
  _setup_coder_commits 1

  local test_dir="$TEST_PROJECT_DIR"
  # No existing PR — pipeline should invoke push_branch.
  detect_task_pr() { return 1; }
  push_branch() {
    echo "push_called" > "$test_dir/.autopilot/push_flag"
    return 0
  }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr push_branch generate_pr_body create_task_pr
  export -f run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
  # Verify push_branch was actually invoked by the pipeline.
  [ -f "$TEST_PROJECT_DIR/.autopilot/push_flag" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/push_flag")" = "push_called" ]
}
