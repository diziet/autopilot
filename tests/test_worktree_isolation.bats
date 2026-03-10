#!/usr/bin/env bats
# Tests for worktree isolation guarantees across the full pipeline cycle.
# Validates: user working tree untouched, worktree persists during review,
# crash recovery cleans dirty worktrees, backward compat with direct checkout.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/dispatcher_setup

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"

# Override setup to enable worktree mode (dispatcher_setup defaults to false).
setup() {
  _init_test_from_template

  load_config "$TEST_PROJECT_DIR"

  AUTOPILOT_USE_WORKTREES="true"

  init_pipeline "$TEST_PROJECT_DIR"
  _create_tasks_file 3
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  _mock_gh
  _mock_claude
  _mock_timeout
}

teardown() {
  # Clean up any worktrees before removing project dir.
  if [[ -d "$TEST_PROJECT_DIR" ]]; then
    git -C "$TEST_PROJECT_DIR" worktree list --porcelain 2>/dev/null | \
      grep '^worktree ' | while read -r _ path; do
        [[ "$path" == "$TEST_PROJECT_DIR" ]] && continue
        git -C "$TEST_PROJECT_DIR" worktree remove --force "$path" 2>/dev/null || true
      done
  fi
}

# --- User working tree untouched ---

@test "isolation: user working tree stays on main during pending tick" {
  _set_state "pending"
  _set_task 1

  # Record main branch HEAD and files before dispatch.
  local main_head_before
  main_head_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  local main_branch_before
  main_branch_before="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr push_branch
  export -f generate_pr_body create_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # Main branch should still be checked out.
  local main_branch_after
  main_branch_after="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$main_branch_after" = "$main_branch_before" ]

  # HEAD should be unchanged (no new commits on main).
  local main_head_after
  main_head_after="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$main_head_after" = "$main_head_before" ]
}

@test "isolation: no dirty files in user working tree after pending tick" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    local work_dir="${7:-$1}"
    echo "feature code" >> "$work_dir/new_feature.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: add feature" -q
    return 0
  }
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr push_branch
  export -f generate_pr_body create_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"

  # User's working tree should have no uncommitted changes outside .autopilot/.
  # .autopilot/ and CLAUDE.md are expected untracked files from pipeline setup.
  local dirty_files
  dirty_files="$(git -C "$TEST_PROJECT_DIR" status --porcelain 2>/dev/null \
    | grep -v '\.autopilot' | grep -v 'CLAUDE.md' | grep -v 'tasks.md' || true)"
  [ -z "$dirty_files" ]
}

@test "isolation: user working tree untouched through full cycle" {
  # Track a sentinel file in the user's working tree.
  echo "user work in progress" > "$TEST_PROJECT_DIR/user_file.txt"
  git -C "$TEST_PROJECT_DIR" add user_file.txt >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add user file" -q

  local main_head_before
  main_head_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  # --- Phase 1: pending → pr_open ---
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr push_branch
  export -f generate_pr_body create_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # --- Phase 2: reviewed → fixed ---
  _set_state "reviewed"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true}}}
JSON
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]

  # User file should still exist and be unchanged.
  [ -f "$TEST_PROJECT_DIR/user_file.txt" ]
  [ "$(cat "$TEST_PROJECT_DIR/user_file.txt")" = "user work in progress" ]

  # Main branch HEAD should be unchanged.
  local main_head_after
  main_head_after="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$main_head_after" = "$main_head_before" ]
}

# --- Worktree persists during review phase ---

@test "isolation: worktree persists during pr_open phase" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1

  # Create the worktree as _handle_pending would.
  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  [ -d "$worktree_path" ]

  # Simulate coder work.
  echo "feature" > "$worktree_path/feature.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: implement" -q

  # Set state to pr_open (reviewer is reading the worktree).
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Tick in pr_open with no test gate result — should stay in pr_open.
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pr_open" ]
  # Worktree must still exist (reviewer needs it).
  [ -d "$worktree_path" ]
}

@test "isolation: worktree persists during reviewed phase" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1

  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  echo "feature" > "$worktree_path/feature.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: implement" -q

  # Reviewed with clean reviews → fixed (no fixer needed).
  _set_state "reviewed"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true}}}
JSON

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]

  # Worktree should still exist (not yet merged).
  [ -d "$worktree_path" ]
}

@test "isolation: worktree persists during fixed phase" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1

  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  echo "feature" > "$worktree_path/feature.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: implement" -q

  # Fixed → merger approves → merged.
  _set_state "fixed"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  run_merger() { return 0; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]

  # Worktree should still exist (cleanup happens in merged handler).
  [ -d "$worktree_path" ]
}

@test "isolation: worktree only removed after merged handler runs" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "pending"
  _set_task 1

  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  echo "feature" > "$worktree_path/feature.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: implement" -q

  _set_state "merged"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  # Before merged handler — worktree exists.
  [ -d "$worktree_path" ]

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  # After merged handler — worktree is cleaned up.
  [ ! -d "$worktree_path" ]
}

# --- Crash recovery cleans dirty worktree ---

@test "isolation: crash recovery cleans dirty worktree on retry" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  # Create worktree with uncommitted changes (simulates coder crash).
  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  echo "uncommitted work" > "$worktree_path/dirty.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  # Staged but not committed — dirty worktree.

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_implementing "$TEST_PROJECT_DIR"

  # Max retries exhausted → diagnosis → advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  # Dirty worktree should be cleaned up (--force).
  [ ! -d "$worktree_path" ]
}

@test "isolation: crash recovery preserves worktree during phase A retry" {
  AUTOPILOT_USE_WORKTREES="true"
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  # Create worktree with a commit (phase A preserves this).
  create_task_branch "$TEST_PROJECT_DIR" 1
  local worktree_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-1"
  echo "partial work" > "$worktree_path/partial.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: partial" -q

  _handle_implementing "$TEST_PROJECT_DIR"

  # Retry count incremented, goes to pending.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
  # Worktree should still exist (phase A preserves branch).
  [ -d "$worktree_path" ]
}

# --- Backward compatibility: AUTOPILOT_USE_WORKTREES=false ---

@test "compat: direct checkout mode works for full pending cycle" {
  AUTOPILOT_USE_WORKTREES="false"
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    local work_dir="${7:-$1}"
    # In direct mode, work_dir should be the project_dir itself.
    echo "$work_dir" > "$test_dir/.autopilot/coder_work_dir"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr push_branch
  export -f generate_pr_body create_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pr_open" ]
  # Coder should have received the project_dir as work_dir.
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/coder_work_dir")" = "$TEST_PROJECT_DIR" ]
  # No worktree directory should exist.
  [ ! -d "$TEST_PROJECT_DIR/.autopilot/worktrees/task-1" ]
}

@test "compat: direct checkout merged cycle advances without worktree cleanup" {
  AUTOPILOT_USE_WORKTREES="false"
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "compat: direct checkout full cycle pending → reviewed → fixed → merged" {
  AUTOPILOT_USE_WORKTREES="false"

  # --- pending → pr_open ---
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  detect_task_pr() { return 1; }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr push_branch
  export -f generate_pr_body create_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # --- reviewed → fixed (clean reviews) ---
  _set_state "reviewed"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true}}}
JSON
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]

  # --- fixed → merged ---
  run_merger() { return 0; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]

  # --- merged → pending (advance to task 2) ---
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}
