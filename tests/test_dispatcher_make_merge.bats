#!/usr/bin/env bats
# Tests for the dispatcher's handling of the `make merge` path: a gate failure
# returns the PR to the fixer, a refusal takes the merge retry path, and
# finalization runs after `make merge` has removed the task worktree.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup
load helpers/fake_make

# Set task 1 with PR 42 in the given status, and write a clean review record.
_setup_task_with_clean_reviews() {
  _set_state "$1"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  echo '{"pr_42":{"general":{"sha":"a","is_clean":true}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"
}

# Put a Makefile with a make merge rule in the task dir (the project dir in
# direct-checkout mode) and install the fake make.
_setup_make_merge_repo() {
  _write_make_merge_makefile "$TEST_PROJECT_DIR"
  _install_fake_make
}

# Write make merge output that ends in a gate failure for task 1.
_write_gate_failure_output() {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  printf 'lint     FAIL (see /tmp/gate-logs/lint.log)\nmerge: refused (closed): gate failed (exit 1): bash gate.sh\n' \
    > "$TEST_PROJECT_DIR/.autopilot/logs/make-merge-task-1.log"
}

# --- _handle_merger_result: MERGER_GATE_FAILED ---

@test "merger result: GATE_FAILED returns to reviewed and uses one task retry" {
  _setup_task_with_clean_reviews "merging"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  _write_gate_failure_output

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_GATE_FAILED"

  [ "$(_get_status)" = "reviewed" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "merger result: GATE_FAILED writes the make merge output to the task's diagnosis hints" {
  _setup_task_with_clean_reviews "merging"
  _write_gate_failure_output

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_GATE_FAILED"

  local hints_file="$TEST_PROJECT_DIR/.autopilot/diagnosis-hints-task-1.md"
  grep -qF "lint     FAIL (see /tmp/gate-logs/lint.log)" "$hints_file"
  grep -qF "make merge pr=42" "$hints_file"
}

@test "merger result: GATE_FAILED removes PR 42 from reviewed.json so the fixer runs" {
  _setup_task_with_clean_reviews "merging"
  _write_gate_failure_output

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_GATE_FAILED"

  run _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq 1 ]
}

@test "merger result: GATE_FAILED at 5 of 5 retries runs diagnosis and advances to task 2" {
  _setup_task_with_clean_reviews "merging"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5
  _write_gate_failure_output
  local diagnosis_called="${BATS_TEST_TMPDIR}/diagnosis_called"
  export DIAGNOSIS_CALLED="$diagnosis_called"
  run_diagnosis() { touch "$DIAGNOSIS_CALLED"; }
  export -f run_diagnosis

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_GATE_FAILED"

  [ -f "$diagnosis_called" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(_get_status)" = "pending" ]
}

# --- _retry_merge_or_fallback with make merge ---

@test "merge retry: make merge success transitions to merged and resets merge retries" {
  _setup_merge_retry_state 1
  _setup_make_merge_repo
  _mock_gh_merge_retry 1 "MERGED" "MERGEABLE"
  _mock_ensure_pr_open

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" 1 42

  grep -qxF "args=merge pr=42" "$FAKE_MAKE_LOG"
  [ "$(_get_status)" = "merged" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merge retry: a make merge refusal stays in merging with merge_retry_count 2" {
  _setup_merge_retry_state 1
  _setup_make_merge_repo
  _mock_gh_merge_retry 1 "OPEN" "MERGEABLE"
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="merge: refused (closed): origin/main moved during the gate; rerun make merge"

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" 1 42

  [ "$(_get_status)" = "merging" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "2" ]
  grep -qF "origin/main moved during the gate" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "merge retry: a make merge gate failure returns to reviewed and resets merge retries" {
  _setup_merge_retry_state 1
  _setup_make_merge_repo
  _mock_gh_merge_retry 1 "OPEN" "MERGEABLE"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="merge: refused (closed): gate failed (exit 1): bash gate.sh"

  _retry_merge_or_fallback "$TEST_PROJECT_DIR" 1 42

  [ "$(_get_status)" = "reviewed" ]
  [ "$(get_merge_retries "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixed end to end with make merge ---

@test "fixed: an approved PR in a repo with a make merge rule is merged by make merge" {
  _setup_task_with_clean_reviews "fixed"
  _setup_make_merge_repo
  _mock_gh_pr_state "MERGED"
  resolve_pre_merge_conflicts() { return 0; }
  _run_pre_merge_tests() { return 0; }
  export -f resolve_pre_merge_conflicts _run_pre_merge_tests
  sleep() { return 0; }
  export -f sleep

  _handle_fixed "$TEST_PROJECT_DIR"

  grep -qxF "args=merge pr=42" "$FAKE_MAKE_LOG"
  grep -qxF "cwd=${TEST_PROJECT_DIR}" "$FAKE_MAKE_LOG"
  [ "$(_get_status)" = "merged" ]
}

# --- _handle_merged after make merge removed the worktree ---

@test "merged: finalization advances to task 2 when make merge already removed the worktree and branch" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1
  create_task_branch "$TEST_PROJECT_DIR" 1
  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  [ -d "$worktree_path" ]

  # make merge removes the worktree it ran in and deletes the local branch.
  # --force because the test repo leaves CLAUDE.md untracked, so the worktree
  # holds an untracked CLAUDE.md symlink.
  git -C "$TEST_PROJECT_DIR" worktree remove --force "$worktree_path"
  git -C "$TEST_PROJECT_DIR" branch -D autopilot/task-1 >/dev/null

  _set_state "merged"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _mock_gh_pr_state "MERGED"
  _mock_metrics
  _pull_main_after_merge() { return 0; }
  export -f _pull_main_after_merge

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  run grep -F "Worktree cleanup failed" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  [ "$status" -eq 1 ]
}
