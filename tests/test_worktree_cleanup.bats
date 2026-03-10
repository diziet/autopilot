#!/usr/bin/env bats
# Tests for worktree cleanup in lib/worktree-cleanup.sh.
# Validates cleanup after merge, cleanup on task skip, stale worktree
# detection, and edge case handling (missing directory, disabled worktrees).

load helpers/git_ops_setup

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/git-ops.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/worktree-cleanup.sh"

# Enable worktree mode for all tests in this file.
setup() {
  _init_test_from_template

  load_config "$TEST_PROJECT_DIR"

  AUTOPILOT_USE_WORKTREES="true"

  # Initialize pipeline state.
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  : # BATS_TEST_TMPDIR auto-cleans
}

# --- cleanup_task_worktree ---

@test "cleanup_task_worktree removes existing worktree" {
  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 1)"
  [ -d "$worktree_path" ]

  cleanup_task_worktree "$TEST_PROJECT_DIR" 1

  [ ! -d "$worktree_path" ]
}

@test "cleanup_task_worktree succeeds when worktree directory is missing" {
  # No worktree created — cleanup should be a no-op.
  run cleanup_task_worktree "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 0 ]
}

@test "cleanup_task_worktree handles dirty worktree" {
  create_task_branch "$TEST_PROJECT_DIR" 2

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 2)"

  # Make worktree dirty.
  echo "uncommitted" > "$worktree_path/dirty.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1

  cleanup_task_worktree "$TEST_PROJECT_DIR" 2
  [ ! -d "$worktree_path" ]
}

@test "cleanup_task_worktree does not delete the branch" {
  create_task_branch "$TEST_PROJECT_DIR" 3

  cleanup_task_worktree "$TEST_PROJECT_DIR" 3

  # Branch should still exist even though worktree is gone.
  git -C "$TEST_PROJECT_DIR" rev-parse --verify "autopilot/task-3" >/dev/null 2>&1
}

@test "cleanup_task_worktree is no-op when worktrees disabled" {
  AUTOPILOT_USE_WORKTREES="false"

  # Even if a directory happens to exist, cleanup should skip it.
  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 4)"
  mkdir -p "$worktree_path"

  cleanup_task_worktree "$TEST_PROJECT_DIR" 4

  # Directory should still exist (not cleaned up).
  [ -d "$worktree_path" ]
}

@test "cleanup_task_worktree handles manually deleted worktree directory" {
  create_task_branch "$TEST_PROJECT_DIR" 5

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 5)"

  # Simulate manual deletion (rm -rf without git worktree remove).
  rm -rf "$worktree_path"

  # Should succeed and prune stale metadata.
  run cleanup_task_worktree "$TEST_PROJECT_DIR" 5
  [ "$status" -eq 0 ]

  # After prune, git worktree list should not reference it.
  local wt_list
  wt_list="$(git -C "$TEST_PROJECT_DIR" worktree list 2>/dev/null)"
  ! echo "$wt_list" | grep -qF "task-5"
}

# --- cleanup_stale_worktrees ---

@test "cleanup_stale_worktrees removes worktree for old task with deleted branch" {
  create_task_branch "$TEST_PROJECT_DIR" 1

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 1)"
  [ -d "$worktree_path" ]

  # Delete the branch but leave the worktree directory.
  git -C "$TEST_PROJECT_DIR" worktree remove --force "$worktree_path" 2>/dev/null
  git -C "$TEST_PROJECT_DIR" branch -D "autopilot/task-1" 2>/dev/null

  # Recreate the directory to simulate orphaned worktree dir.
  mkdir -p "$worktree_path"

  # Set current task to 5 (task 1 is old).
  write_state_num "$TEST_PROJECT_DIR" "current_task" 5

  cleanup_stale_worktrees "$TEST_PROJECT_DIR"

  [ ! -d "$worktree_path" ]
}

@test "cleanup_stale_worktrees skips worktree with existing branch" {
  create_task_branch "$TEST_PROJECT_DIR" 2

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 2)"

  # Set current task to 5 (task 2 is old, but branch still exists).
  write_state_num "$TEST_PROJECT_DIR" "current_task" 5

  cleanup_stale_worktrees "$TEST_PROJECT_DIR"

  # Worktree should still be there because branch exists.
  [ -d "$worktree_path" ]
}

@test "cleanup_stale_worktrees skips current task worktree" {
  create_task_branch "$TEST_PROJECT_DIR" 3

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 3)"

  # Current task is 3 — should not be cleaned up.
  write_state_num "$TEST_PROJECT_DIR" "current_task" 3

  cleanup_stale_worktrees "$TEST_PROJECT_DIR"

  [ -d "$worktree_path" ]
}

@test "cleanup_stale_worktrees is no-op when worktrees disabled" {
  AUTOPILOT_USE_WORKTREES="true"
  create_task_branch "$TEST_PROJECT_DIR" 1
  AUTOPILOT_USE_WORKTREES="false"

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 1)"

  write_state_num "$TEST_PROJECT_DIR" "current_task" 5

  cleanup_stale_worktrees "$TEST_PROJECT_DIR"

  # Nothing should be removed.
  [ -d "$worktree_path" ]
}

@test "cleanup_stale_worktrees handles empty worktrees directory" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/worktrees"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  run cleanup_stale_worktrees "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "cleanup_stale_worktrees handles no worktrees directory" {
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  run cleanup_stale_worktrees "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- Integration: worktree removed after merge flow ---

@test "worktree cleanup after full create-commit-cleanup cycle" {
  create_task_branch "$TEST_PROJECT_DIR" 10

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 10)"

  # Simulate coder work in the worktree.
  echo "feature code" > "$worktree_path/feature.txt"
  git -C "$worktree_path" add -A >/dev/null 2>&1
  git -C "$worktree_path" commit -m "feat: add feature" -q

  # Cleanup worktree (simulates post-merge cleanup).
  cleanup_task_worktree "$TEST_PROJECT_DIR" 10

  [ ! -d "$worktree_path" ]

  # Branch should still exist for potential remote cleanup later.
  git -C "$TEST_PROJECT_DIR" rev-parse --verify "autopilot/task-10" >/dev/null 2>&1
}

@test "cleanup_task_worktree with fallback to manual rm" {
  create_task_branch "$TEST_PROJECT_DIR" 11

  local worktree_path
  worktree_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 11)"

  # Corrupt the worktree so git worktree remove fails.
  # Remove the .git file that links to the main repo.
  rm -f "$worktree_path/.git"

  cleanup_task_worktree "$TEST_PROJECT_DIR" 11

  # Should still be cleaned up via manual rm fallback.
  [ ! -d "$worktree_path" ]
}
