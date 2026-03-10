#!/usr/bin/env bats
# Tests for delete_task_branch in lib/git-ops.sh.
# Split from test_git_ops.bats for better parallel scheduling.

load helpers/git_ops_setup

# --- delete_task_branch (13 tests: 4 basic + 5 hotfix + 4 dirty-worktree) ---

@test "delete_task_branch removes local branch" {
  create_task_branch "$TEST_PROJECT_DIR" 4
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  task_branch_exists "$TEST_PROJECT_DIR" 4
  delete_task_branch "$TEST_PROJECT_DIR" 4
  run task_branch_exists "$TEST_PROJECT_DIR" 4
  [ "$status" -eq 1 ]
}

@test "delete_task_branch returns 1 for non-existent branch" {
  run delete_task_branch "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 1 ]
}

@test "delete_task_branch switches away when branch is checked out" {
  create_task_branch "$TEST_PROJECT_DIR" 10
  # Confirm we are ON the task branch.
  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-10" ]

  # Delete while checked out — should switch to main first.
  delete_task_branch "$TEST_PROJECT_DIR" 10

  # Verify we're now on main.
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]

  # Verify branch is gone.
  run task_branch_exists "$TEST_PROJECT_DIR" 10
  [ "$status" -eq 1 ]
}

@test "delete_task_branch succeeds when branch is not checked out" {
  create_task_branch "$TEST_PROJECT_DIR" 11
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1

  delete_task_branch "$TEST_PROJECT_DIR" 11

  # Verify still on main and branch is gone.
  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 11
  [ "$status" -eq 1 ]
}

@test "delete_task_branch uses master when main is absent" {
  # Create a repo with master as default branch (no main).
  local master_dir
  master_dir="$BATS_TEST_TMPDIR/master_dir"
  mkdir -p "$master_dir"
  git -C "$master_dir" init -b master >/dev/null 2>&1
  git -C "$master_dir" config user.email "test@test.com"
  git -C "$master_dir" config user.name "Test"
  echo "init" > "$master_dir/README.md"
  git -C "$master_dir" add -A >/dev/null 2>&1
  git -C "$master_dir" commit -m "Initial commit" >/dev/null 2>&1

  # AUTOPILOT_TARGET_BRANCH defaults to empty — auto-detect should find master.
  create_task_branch "$master_dir" 20

  local current
  current="$(git -C "$master_dir" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-20" ]

  # Delete — should detect master as default and switch to it.
  delete_task_branch "$master_dir" 20

  current="$(git -C "$master_dir" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "master" ]
  run task_branch_exists "$master_dir" 20
  [ "$status" -eq 1 ]
}

@test "delete_task_branch leaves working tree on target not detached HEAD" {
  create_task_branch "$TEST_PROJECT_DIR" 30
  # Confirm we are on the task branch.
  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-30" ]

  # Delete while checked out.
  delete_task_branch "$TEST_PROJECT_DIR" 30

  # Verify HEAD is a named branch, not detached (detached returns "HEAD").
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" != "HEAD" ]
  [ "$current" = "main" ]

  # Double-check: symbolic-ref should succeed (fails on detached HEAD).
  git -C "$TEST_PROJECT_DIR" symbolic-ref HEAD
}

@test "delete_task_branch falls back via symbolic-ref when main absent locally" {
  # Create a bare remote with a 'develop' default branch.
  local bare_dir repo_dir
  bare_dir="$BATS_TEST_TMPDIR/bare_dir"
  repo_dir="$BATS_TEST_TMPDIR/repo_dir"
  mkdir -p "$bare_dir" "$repo_dir"
  git init --bare "$bare_dir/remote.git" >/dev/null 2>&1

  # Init repo with develop as default, push to bare remote.
  git -C "$repo_dir" init -b develop >/dev/null 2>&1
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "init" > "$repo_dir/README.md"
  git -C "$repo_dir" add -A >/dev/null 2>&1
  git -C "$repo_dir" commit -m "Initial commit" >/dev/null 2>&1
  git -C "$repo_dir" remote add origin "$bare_dir/remote.git"
  git -C "$repo_dir" push -u origin develop >/dev/null 2>&1

  # Set bare repo HEAD to develop so clone picks it up via origin/HEAD.
  git -C "$bare_dir/remote.git" symbolic-ref HEAD refs/heads/develop

  # Clone so that origin/HEAD is set automatically.
  local clone_dir
  clone_dir="$BATS_TEST_TMPDIR/clone_dir"
  mkdir -p "$clone_dir"
  git clone "$bare_dir/remote.git" "$clone_dir/work" >/dev/null 2>&1
  git -C "$clone_dir/work" config user.email "test@test.com"
  git -C "$clone_dir/work" config user.name "Test"

  # Neither main nor master exist. detect_default_branch should use symbolic-ref.
  local detected
  detected="$(detect_default_branch "$clone_dir/work")"
  [ "$detected" = "develop" ]

  # Create and delete task branch while checked out.
  create_task_branch "$clone_dir/work" 40
  delete_task_branch "$clone_dir/work" 40

  local current
  current="$(git -C "$clone_dir/work" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "develop" ]
}

@test "delete_task_branch logs error but does not crash on non-existent branch" {
  # Attempt to delete a branch that was never created.
  run delete_task_branch "$TEST_PROJECT_DIR" 999
  [ "$status" -eq 1 ]

  # Verify the working tree is intact — still on main.
  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]

  # Verify log recorded the error.
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  [[ -f "$log_file" ]]
  grep -q "Failed to delete branch" "$log_file"
}

@test "delete_task_branch full cycle: checked-out branch → delete → recreate → proceed" {
  # Step 1: Create and checkout task branch, make a commit on it.
  create_task_branch "$TEST_PROJECT_DIR" 50
  echo "stale work" > "$TEST_PROJECT_DIR/stale.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Stale work" >/dev/null 2>&1

  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-50" ]

  # Step 2: Delete the branch (while checked out) — stale branch reset.
  delete_task_branch "$TEST_PROJECT_DIR" 50

  # Should be on main now.
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]

  # Step 3: Recreate the branch fresh from main.
  create_task_branch "$TEST_PROJECT_DIR" 50
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-50" ]

  # Step 4: Fresh branch — stale file should NOT exist.
  [ ! -f "$TEST_PROJECT_DIR/stale.txt" ]

  # Step 5: Coder can proceed — new commits work.
  echo "fresh work" > "$TEST_PROJECT_DIR/fresh.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Fresh work" >/dev/null 2>&1

  local log_output
  log_output="$(git -C "$TEST_PROJECT_DIR" log --oneline -1)"
  [[ "$log_output" == *"Fresh work"* ]]
}

@test "create_task_branch works correctly after delete_task_branch" {
  # Create, then delete, then create again — full dispatcher cycle.
  create_task_branch "$TEST_PROJECT_DIR" 60
  echo "first attempt" > "$TEST_PROJECT_DIR/attempt.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "First attempt" >/dev/null 2>&1

  # Record main's SHA for later comparison.
  local main_sha
  main_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse main)"

  # Delete (currently checked out).
  delete_task_branch "$TEST_PROJECT_DIR" 60

  # Recreate — should branch from main.
  create_task_branch "$TEST_PROJECT_DIR" 60

  local branch_sha
  branch_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$main_sha" = "$branch_sha" ]

  # Verify we're on the task branch.
  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-60" ]
}

# --- delete_task_branch dirty-worktree tests ---

@test "delete_task_branch succeeds with clean working tree" {
  create_task_branch "$TEST_PROJECT_DIR" 70
  echo "work" > "$TEST_PROJECT_DIR/work.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Clean work" >/dev/null 2>&1

  # Working tree is clean — delete should succeed.
  delete_task_branch "$TEST_PROJECT_DIR" 70

  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 70
  [ "$status" -eq 1 ]
}

@test "delete_task_branch succeeds with modified tracked file" {
  create_task_branch "$TEST_PROJECT_DIR" 71
  echo "committed" > "$TEST_PROJECT_DIR/tracked.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add tracked file" >/dev/null 2>&1

  # Modify the tracked file without committing (simulates dirty package-lock.json).
  echo "modified-uncommitted" > "$TEST_PROJECT_DIR/tracked.txt"

  # Force checkout should discard the dirty file and switch branches.
  delete_task_branch "$TEST_PROJECT_DIR" 71

  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 71
  [ "$status" -eq 1 ]
}

@test "delete_task_branch succeeds with untracked files" {
  create_task_branch "$TEST_PROJECT_DIR" 72
  echo "committed" > "$TEST_PROJECT_DIR/src.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add src" >/dev/null 2>&1

  # Create untracked files (simulates build artifacts left behind).
  echo "untracked" > "$TEST_PROJECT_DIR/build-output.tmp"
  mkdir -p "$TEST_PROJECT_DIR/dist"
  echo "artifact" > "$TEST_PROJECT_DIR/dist/bundle.js"

  # Delete should force checkout and clean untracked files.
  delete_task_branch "$TEST_PROJECT_DIR" 72

  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "main" ]
  run task_branch_exists "$TEST_PROJECT_DIR" 72
  [ "$status" -eq 1 ]

  # Untracked files from the task branch should be cleaned.
  [ ! -f "$TEST_PROJECT_DIR/build-output.tmp" ]
  [ ! -d "$TEST_PROJECT_DIR/dist" ]
}

@test "delete_task_branch logs error when force checkout target does not exist" {
  create_task_branch "$TEST_PROJECT_DIR" 73

  # Point to a non-existent target branch to force checkout failure.
  AUTOPILOT_TARGET_BRANCH="nonexistent-branch"

  run delete_task_branch "$TEST_PROJECT_DIR" 73
  [ "$status" -eq 1 ]

  # Verify clear error was logged with the reason.
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  [[ -f "$log_file" ]]
  grep -q "force checkout nonexistent-branch failed" "$log_file"
}
