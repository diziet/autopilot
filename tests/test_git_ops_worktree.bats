#!/usr/bin/env bats
# Tests for worktree-based branch operations in lib/git-ops.sh.
# Validates create, delete, exists, and path helpers when AUTOPILOT_USE_WORKTREES=true.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/git_ops_setup

# Override the default (false) set in git_ops_setup to enable worktree mode.
_enable_worktrees() {
  AUTOPILOT_USE_WORKTREES="true"
}

# --- get_task_worktree_path ---

@test "get_task_worktree_path returns correct path" {
  local result
  result="$(get_task_worktree_path "$TEST_PROJECT_DIR" 5)"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/worktrees/task-5" ]
}

@test "get_task_worktree_path handles task number 1" {
  local result
  result="$(get_task_worktree_path "$TEST_PROJECT_DIR" 1)"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/worktrees/task-1" ]
}

@test "get_task_worktree_path handles large task numbers" {
  local result
  result="$(get_task_worktree_path "$TEST_PROJECT_DIR" 999)"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/worktrees/task-999" ]
}

# --- _use_worktrees ---

@test "_use_worktrees returns 0 when AUTOPILOT_USE_WORKTREES=true" {
  AUTOPILOT_USE_WORKTREES="true"
  _use_worktrees
}

@test "_use_worktrees returns 1 when AUTOPILOT_USE_WORKTREES=false" {
  AUTOPILOT_USE_WORKTREES="false"
  run _use_worktrees
  [ "$status" -eq 1 ]
}

@test "_use_worktrees defaults to true when unset" {
  unset AUTOPILOT_USE_WORKTREES
  _use_worktrees
}

# --- create_task_branch (worktree mode) ---

@test "worktree: create_task_branch creates worktree in correct location" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 3

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 3)"
  [ -d "$worktree_path" ]
}

@test "worktree: create_task_branch creates the branch" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 4

  # Branch should exist in the main repo.
  git -C "$TEST_PROJECT_DIR" rev-parse --verify "autopilot/task-4" >/dev/null 2>&1
}

@test "worktree: created worktree has correct branch checked out" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 5

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 5)"
  local branch
  branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-5" ]
}

@test "worktree: main working tree is not affected by create" {
  _enable_worktrees

  local main_branch_before
  main_branch_before="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"

  create_task_branch "$TEST_PROJECT_DIR" 6

  local main_branch_after
  main_branch_after="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$main_branch_before" = "$main_branch_after" ]
}

@test "worktree: create_task_branch uses custom prefix" {
  _enable_worktrees
  AUTOPILOT_BRANCH_PREFIX="custom"
  create_task_branch "$TEST_PROJECT_DIR" 7

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 7)"
  local branch
  branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "custom/task-7" ]
}

@test "worktree: create_task_branch fails if branch already exists" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 8

  run create_task_branch "$TEST_PROJECT_DIR" 8
  [ "$status" -eq 1 ]
}

@test "worktree: create_task_branch branches from target" {
  _enable_worktrees
  AUTOPILOT_TARGET_BRANCH="main"

  echo "extra" > "$TEST_PROJECT_DIR/extra.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Extra commit" >/dev/null 2>&1
  local main_sha
  main_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  create_task_branch "$TEST_PROJECT_DIR" 9

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 9)"
  local branch_sha
  branch_sha="$(git -C "$worktree_path" rev-parse HEAD)"
  [ "$main_sha" = "$branch_sha" ]
}

# --- task_branch_exists (worktree mode) ---

@test "worktree: task_branch_exists returns 0 when worktree exists" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 10
  task_branch_exists "$TEST_PROJECT_DIR" 10
}

@test "worktree: task_branch_exists returns 1 for non-existent task" {
  _enable_worktrees
  run task_branch_exists "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 1 ]
}

@test "worktree: task_branch_exists detects branch even without worktree dir" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 11

  # Remove the worktree directory but keep the branch.
  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 11)"
  git -C "$TEST_PROJECT_DIR" worktree remove --force "$worktree_path" 2>/dev/null

  # Branch still exists, so task_branch_exists should return 0.
  task_branch_exists "$TEST_PROJECT_DIR" 11
}

# --- delete_task_branch (worktree mode) ---

@test "worktree: delete_task_branch removes worktree and branch" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 20

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 20)"
  [ -d "$worktree_path" ]

  delete_task_branch "$TEST_PROJECT_DIR" 20

  # Worktree directory should be gone.
  [ ! -d "$worktree_path" ]

  # Branch should be gone.
  run task_branch_exists "$TEST_PROJECT_DIR" 20
  [ "$status" -eq 1 ]
}

@test "worktree: delete_task_branch succeeds with dirty worktree" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 21

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 21)"

  # Make the worktree dirty (simulates coder crash with uncommitted changes).
  echo "uncommitted work" > "$worktree_path/dirty_file.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1

  # Delete should succeed with --force.
  delete_task_branch "$TEST_PROJECT_DIR" 21

  [ ! -d "$worktree_path" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 21
  [ "$status" -eq 1 ]
}

@test "worktree: delete_task_branch succeeds with untracked files" {
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" 22

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 22)"

  # Add untracked files (simulates build artifacts).
  mkdir -p "$worktree_path/dist"
  echo "artifact" > "$worktree_path/dist/bundle.js"

  delete_task_branch "$TEST_PROJECT_DIR" 22

  [ ! -d "$worktree_path" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 22
  [ "$status" -eq 1 ]
}

@test "worktree: delete_task_branch returns 1 for non-existent branch" {
  _enable_worktrees
  run delete_task_branch "$TEST_PROJECT_DIR" 999
  [ "$status" -eq 1 ]
}

@test "worktree: delete_task_branch does not affect main working tree" {
  _enable_worktrees

  local main_branch_before
  main_branch_before="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"

  create_task_branch "$TEST_PROJECT_DIR" 23
  delete_task_branch "$TEST_PROJECT_DIR" 23

  local main_branch_after
  main_branch_after="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$main_branch_before" = "$main_branch_after" ]
}

# --- Full cycle (worktree mode) ---

@test "worktree: full cycle — create, commit in worktree, delete, recreate" {
  _enable_worktrees

  # Create worktree and make a commit in it.
  create_task_branch "$TEST_PROJECT_DIR" 30

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 30)"

  echo "stale work" > "$worktree_path/stale.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "Stale work" >/dev/null 2>&1

  # Delete the worktree and branch.
  delete_task_branch "$TEST_PROJECT_DIR" 30

  [ ! -d "$worktree_path" ]

  # Recreate — should get a fresh branch from main.
  create_task_branch "$TEST_PROJECT_DIR" 30

  [ -d "$worktree_path" ]

  # Stale file should NOT exist in the fresh worktree.
  [ ! -f "$worktree_path/stale.txt" ]

  # New commits should work.
  echo "fresh work" > "$worktree_path/fresh.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "Fresh work" >/dev/null 2>&1

  local log_output
  log_output="$(git -C "$worktree_path" log --oneline -1)"
  [[ "$log_output" == *"Fresh work"* ]]
}

# --- Fallback to direct checkout ---

@test "fallback: AUTOPILOT_USE_WORKTREES=false uses direct checkout" {
  AUTOPILOT_USE_WORKTREES="false"

  create_task_branch "$TEST_PROJECT_DIR" 40
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-40" ]

  # No worktree directory should exist.
  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 40)"
  [ ! -d "$worktree_path" ]
}

@test "fallback: delete uses direct checkout mode" {
  AUTOPILOT_USE_WORKTREES="false"

  create_task_branch "$TEST_PROJECT_DIR" 41
  delete_task_branch "$TEST_PROJECT_DIR" 41

  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ]

  run task_branch_exists "$TEST_PROJECT_DIR" 41
  [ "$status" -eq 1 ]
}
