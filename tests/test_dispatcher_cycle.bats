#!/usr/bin/env bats
# Integration tests for the full dispatcher state machine cycle.
# Uses the mock harness from tests/fixtures/bin/ (Task 41) with
# realistic agent behavior: mock claude commits code, mock gh
# creates PRs. Tests validate state transitions end-to-end.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"

setup_file() {
  _create_test_template

  # Build a cycle-specific template: git repo + bare remote, pre-pushed.
  _CYCLE_TEMPLATE_DIR="${BATS_FILE_TMPDIR}/cycle_template"
  export _CYCLE_TEMPLATE_DIR
  mkdir -p "$_CYCLE_TEMPLATE_DIR"

  # Build bare remote.
  local bare_dir="${_CYCLE_TEMPLATE_DIR}/bare"
  mkdir -p "$bare_dir"
  git init --bare "$bare_dir" -q -b main 2>/dev/null

  # Build local repo with tasks, CLAUDE.md, state, and push to bare remote.
  local repo_dir="${_CYCLE_TEMPLATE_DIR}/repo"
  _fast_copy "$_TEMPLATE_GIT_DIR" "$repo_dir"
  mkdir -p "$repo_dir/.autopilot/logs" "$repo_dir/.autopilot/locks"
  echo "$_TEMPLATE_STATE_JSON" > "$repo_dir/.autopilot/state.json"
  printf '## Task 1: Test task 1\nDo thing 1.\n\n## Task 2: Test task 2\nDo thing 2.\n\n## Task 3: Test task 3\nDo thing 3.\n\n' > "$repo_dir/tasks.md"
  echo "# Test Project" > "$repo_dir/CLAUDE.md"
  git -C "$repo_dir" add -A >/dev/null 2>&1
  git -C "$repo_dir" commit -m "add test files" -q 2>/dev/null || true
  git -C "$repo_dir" remote set-url origin "$bare_dir" 2>/dev/null || \
    git -C "$repo_dir" remote add origin "$bare_dir"
  git -C "$repo_dir" push -u origin main >/dev/null 2>&1

  # Timeout mock is provided by _TEMPLATE_MOCK_DIR (via _create_test_template).
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  # Copy pre-built templates (fast COW copy on APFS).
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_BARE_REMOTE="$BATS_TEST_TMPDIR/bare_remote"
  GH_MOCK_DIR="$BATS_TEST_TMPDIR/gh_mock"
  CLAUDE_MOCK_DIR="$BATS_TEST_TMPDIR/claude_mock"

  _fast_copy "${_CYCLE_TEMPLATE_DIR}/repo" "$TEST_PROJECT_DIR"
  _fast_copy "${_CYCLE_TEMPLATE_DIR}/bare" "$TEST_BARE_REMOTE"
  mkdir -p "$GH_MOCK_DIR" "$CLAUDE_MOCK_DIR"

  export GH_MOCK_DIR CLAUDE_MOCK_DIR

  # Point local repo's remote at the per-test bare remote copy.
  git -C "$TEST_PROJECT_DIR" remote set-url origin "$TEST_BARE_REMOTE"

  # Reset environment and config.
  _unset_autopilot_vars
  _set_defaults
  _AUTOPILOT_CONFIG_LOADED=1
  AUTOPILOT_USE_WORKTREES="false"

  # Put fixture mocks and template mocks on PATH.
  FIXTURES_BIN="$BATS_TEST_DIRNAME/fixtures/bin"
  export PATH="${FIXTURES_BIN}:${_TEMPLATE_MOCK_DIR}:${PATH}"

  # Configure gh mock to return PR URL with extractable number.
  _configure_gh_mock

  # Mock preflight to skip dependency/auth checks (tested separately).
  run_preflight() { return 0; }
  export -f run_preflight

  # Reset caches to prevent cross-test contamination.
  _reset_git_ops_caches
  _reset_tasks_caches

  # Override get_repo_slug since tests use a local bare remote (not GitHub URL).
  get_repo_slug() { echo "testowner/testrepo"; }
  export -f get_repo_slug
}

# --- Setup Helpers ---

# Configure gh mock with custom PR URL.
_configure_gh_mock() {
  echo "https://github.com/testowner/testrepo/pull/42" \
    > "$GH_MOCK_DIR/pr-create-response.txt"
}

# Write mock actions.sh that commits in the project directory.
_write_coder_actions() {
  local no_push="${1:-}"
  cat > "$CLAUDE_MOCK_DIR/actions.sh" << ACTIONS
echo "mock change" > "$TEST_PROJECT_DIR/mock-output.txt"
git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
git -C "$TEST_PROJECT_DIR" commit -m "feat: mock claude commit" >/dev/null 2>&1
ACTIONS
  if [[ -z "$no_push" ]]; then
    cat >> "$CLAUDE_MOCK_DIR/actions.sh" << ACTIONS
git -C "$TEST_PROJECT_DIR" push >/dev/null 2>&1 || true
ACTIONS
  fi
}

# --- State Helpers ---

# Set pipeline state.
_set_state() { write_state "$TEST_PROJECT_DIR" "status" "$1"; }

# Set current task number.
_set_task() { write_state_num "$TEST_PROJECT_DIR" "current_task" "$1"; }

# Read pipeline status.
_get_status() { read_state "$TEST_PROJECT_DIR" "status"; }

# Read a state field.
_get_state() { read_state "$TEST_PROJECT_DIR" "$1"; }

# ============================================================
# Test 1: Happy path — pending to pr_open
# ============================================================

@test "cycle: pending to pr_open — coder commits without push" {
  _set_state "pending"
  _set_task 1

  # Claude mock commits but does NOT push (common coder behavior).
  _write_coder_actions "no_push"

  # No existing PR — dispatcher will detect local commits and push.
  detect_task_pr() { return 1; }
  export -f detect_task_pr

  # Mock background test gate and reviewer trigger.
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_test_gate_background _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should advance to pr_open.
  [ "$(_get_status)" = "pr_open" ]

  # PR number should be written to state.
  [ "$(_get_state "pr_number")" = "42" ]

  # Verify branch was pushed to bare remote.
  local remote_branches
  remote_branches="$(git -C "$TEST_BARE_REMOTE" branch 2>/dev/null)"
  [[ "$remote_branches" == *"autopilot/task-1"* ]]

  # Verify gh pr create was called.
  [ -f "$GH_MOCK_DIR/pr-create-calls.log" ]
}

# ============================================================
# Test 2: Stale branch recovery
# ============================================================

@test "cycle: stale branch deleted and recreated on pending" {
  _set_state "pending"
  _set_task 1

  # Create a stale branch (leftover from a prior failed run).
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q
  local current_branch
  current_branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current_branch" = "autopilot/task-1" ]

  # State is pending (simulating restart after crash).
  _set_state "pending"

  # Claude mock creates file and commits without push.
  _write_coder_actions "no_push"

  detect_task_pr() { return 1; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"

  # Dispatcher should: checkout main → delete stale branch →
  # recreate branch → spawn coder → detect commits → push → create PR.
  [ "$(_get_status)" = "pr_open" ]

  # Current branch should be the task branch (recreated).
  current_branch="$(git -C "$TEST_PROJECT_DIR" \
    rev-parse --abbrev-ref HEAD)"
  [ "$current_branch" = "autopilot/task-1" ]
}

# ============================================================
# Test 3: Coder timeout recovery (exit 124)
# ============================================================

@test "cycle: coder timeout increments retry, state back to pending" {
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  # Mock claude to exit with 124 (timeout).
  export CLAUDE_MOCK_EXIT=124

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should return to pending after timeout.
  [ "$(_get_status)" = "pending" ]

  # Retry count should be incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "cycle: coder timeout with existing branch still recovers" {
  _set_state "pending"
  _set_task 1

  # Pre-create task branch with a commit (simulating partial progress
  # from a prior run). Branch is deleted and recreated fresh on every
  # retry — this is intentional to ensure a clean starting state.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q
  echo "partial work" > "$TEST_PROJECT_DIR/partial.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: partial" -q
  git -C "$TEST_PROJECT_DIR" checkout main -q

  # retry_count=1 so pending handler skips preflight.
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 1

  # Mock claude to timeout (exit 124 skips actions).
  export CLAUDE_MOCK_EXIT=124

  dispatch_tick "$TEST_PROJECT_DIR"

  # State back to pending with incremented retry.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "2" ]
}

# ============================================================
# Test 4: Coder crash recovery (exit 1)
# ============================================================

@test "cycle: coder crash increments retry, state back to pending" {
  _set_state "pending"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  # Mock claude to crash with exit 1.
  export CLAUDE_MOCK_EXIT=1

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should return to pending.
  [ "$(_get_status)" = "pending" ]

  # Retry count should be incremented.
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "cycle: implementing state on fresh tick triggers crash recovery" {
  # Simulate coder process dying between ticks.
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  dispatch_tick "$TEST_PROJECT_DIR"

  # Crash recovery: state back to pending, retry incremented.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# ============================================================
# Test 5: Full cycle to merge
# ============================================================

@test "cycle: full pending→pr_open→reviewed→fixed→merged→pending" {
  _set_state "pending"
  _set_task 1

  # --- Step 1: pending → implementing → pr_open ---
  _write_coder_actions "no_push"
  detect_task_pr() { return 1; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
  [ "$(_get_state "pr_number")" = "42" ]

  # --- Step 2: pr_open → reviewed (external reviewer) ---
  update_status "$TEST_PROJECT_DIR" "reviewed"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true},"security":{"sha":"a","is_clean":true}}}
JSON

  # --- Step 3: reviewed → fixed (all clean, skip fixer) ---
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]

  # --- Step 4: fixed → merging → merged ---
  run_merger() { return "$MERGER_APPROVE"; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]

  # --- Step 5: merged → pending (advance to task 2) ---
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  export -f record_task_complete record_phase_durations
  export -f generate_task_summary_bg should_run_spec_review

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(_get_state "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "0" ]

  # Verify state.json correctness.
  local state_file="${TEST_PROJECT_DIR}/.autopilot/state.json"
  [ -f "$state_file" ]
  [ "$(jq -r '.status' "$state_file")" = "pending" ]
  [ "$(jq -r '.current_task' "$state_file")" = "2" ]
}

@test "cycle: full cycle with metrics CSV row" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "task_started_at" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Use real record_task_complete to verify CSV output.
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # Verify metrics CSV has a row for completed task 1.
  local metrics_file="${TEST_PROJECT_DIR}/.autopilot/metrics.csv"
  [ -f "$metrics_file" ]

  # Check header.
  [[ "$(head -1 "$metrics_file")" == "task_number,"* ]]

  # Check data row for task 1.
  local data_line
  data_line="$(grep '^1,' "$metrics_file")"
  [[ -n "$data_line" ]]
  [[ "$data_line" == *"merged"* ]]
  [[ "$data_line" == *"42"* ]]
}

# ============================================================
# Test 6: Main pulled after merge
# ============================================================

@test "cycle: main is pulled after merge so next task has latest code" {
  # Simulate a merged PR by pushing a commit to the bare remote's main
  # from a separate clone, then verify _handle_merged pulls it.
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Create a separate clone and push a new commit to main (simulating
  # the merged PR's changes appearing on the remote).
  local other_clone
  other_clone="$BATS_TEST_TMPDIR/other_clone"
  mkdir -p "$other_clone"
  git clone "$TEST_BARE_REMOTE" "$other_clone" -q 2>/dev/null
  git -C "$other_clone" config user.email "test@test.com"
  git -C "$other_clone" config user.name "Test"
  echo "merged-pr-content" > "$other_clone/merged-file.txt"
  git -C "$other_clone" add -A >/dev/null 2>&1
  git -C "$other_clone" commit -m "feat: merged PR content" -q
  git -C "$other_clone" push origin main -q 2>/dev/null

  # Record the remote SHA for verification.
  local remote_sha
  remote_sha="$(git -C "$other_clone" rev-parse HEAD)"

  # Mock metrics/summary functions.
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations
  export -f generate_task_summary_bg should_run_spec_review
  export -f record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should advance to pending.
  [ "$(_get_status)" = "pending" ]
  [ "$(_get_state "current_task")" = "2" ]

  # Working tree should now have the merged PR's file.
  [ -f "$TEST_PROJECT_DIR/merged-file.txt" ]
  [ "$(cat "$TEST_PROJECT_DIR/merged-file.txt")" = "merged-pr-content" ]

  # Local main HEAD should match the remote SHA.
  local local_sha
  local_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$local_sha" = "$remote_sha" ]
}

@test "cycle: next task branches from up-to-date main after merge" {
  # End-to-end: merged → pending (with pull) → new branch has latest code.
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Push a new commit to the remote to simulate the merged PR.
  local other_clone
  other_clone="$BATS_TEST_TMPDIR/other_clone"
  mkdir -p "$other_clone"
  git clone "$TEST_BARE_REMOTE" "$other_clone" -q 2>/dev/null
  git -C "$other_clone" config user.email "test@test.com"
  git -C "$other_clone" config user.name "Test"
  echo "pr-changes" > "$other_clone/from-pr.txt"
  git -C "$other_clone" add -A >/dev/null 2>&1
  git -C "$other_clone" commit -m "feat: from merged PR" -q
  git -C "$other_clone" push origin main -q 2>/dev/null

  # Mock metrics/summary for merged → pending transition.
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations
  export -f generate_task_summary_bg should_run_spec_review
  export -f record_phase_transition

  # Step 1: merged → pending (pulls latest main).
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]

  # Step 2: pending → pr_open (creates branch from updated main).
  _write_coder_actions "no_push"
  detect_task_pr() { return 1; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # The new task branch should contain the merged PR's file.
  [ -f "$TEST_PROJECT_DIR/from-pr.txt" ]
  [ "$(cat "$TEST_PROJECT_DIR/from-pr.txt")" = "pr-changes" ]

}

@test "cycle: last task merged transitions to completed" {
  _set_state "merged"
  _set_task 3
  write_state "$TEST_PROJECT_DIR" "pr_number" "99"

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations
  export -f generate_task_summary_bg should_run_spec_review
  export -f record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "completed" ]
  [ "$(jq -r '.status' \
    "${TEST_PROJECT_DIR}/.autopilot/state.json")" = "completed" ]
}
