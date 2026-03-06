#!/usr/bin/env bats
# Tests for lib/git-ops.sh — Git operations (branch, commit, PR) for Autopilot.

load helpers/git_ops_setup

# --- build_branch_name ---

@test "build_branch_name uses default prefix" {
  local result
  result="$(build_branch_name 5)"
  [ "$result" = "autopilot/task-5" ]
}

@test "build_branch_name uses custom prefix from config" {
  AUTOPILOT_BRANCH_PREFIX="pr-pipeline"
  local result
  result="$(build_branch_name 12)"
  [ "$result" = "pr-pipeline/task-12" ]
}

@test "build_branch_name handles task number 1" {
  local result
  result="$(build_branch_name 1)"
  [ "$result" = "autopilot/task-1" ]
}

# --- create_task_branch ---

@test "create_task_branch creates and checks out new branch" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-3" ]
}

@test "create_task_branch uses custom prefix" {
  AUTOPILOT_BRANCH_PREFIX="custom"
  create_task_branch "$TEST_PROJECT_DIR" 7
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "custom/task-7" ]
}

@test "create_task_branch fails if branch already exists" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  # Go back to main.
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  # Try to create the same branch again.
  run create_task_branch "$TEST_PROJECT_DIR" 1
  [ "$status" -eq 1 ]
}

@test "create_task_branch branches from target branch" {
  AUTOPILOT_TARGET_BRANCH="main"
  # Create a commit on main to verify branching point.
  echo "extra" > "$TEST_PROJECT_DIR/extra.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Extra commit" >/dev/null 2>&1
  local main_sha
  main_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  create_task_branch "$TEST_PROJECT_DIR" 2
  local branch_sha
  branch_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$main_sha" = "$branch_sha" ]
}

# --- task_branch_exists ---

@test "task_branch_exists returns 0 for existing local branch" {
  create_task_branch "$TEST_PROJECT_DIR" 5
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  task_branch_exists "$TEST_PROJECT_DIR" 5
}

@test "task_branch_exists returns 1 for non-existent branch" {
  run task_branch_exists "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 1 ]
}

# --- delete_task_branch (9 tests: 4 basic + 5 hotfix) ---

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
  master_dir="$(mktemp -d)"
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

  rm -rf "$master_dir"
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
  bare_dir="$(mktemp -d)"
  repo_dir="$(mktemp -d)"
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
  clone_dir="$(mktemp -d)"
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

  rm -rf "$bare_dir" "$repo_dir" "$clone_dir"
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

# --- detect_default_branch ---

@test "detect_default_branch returns main for repo with main branch" {
  local result
  result="$(detect_default_branch "$TEST_PROJECT_DIR")"
  [ "$result" = "main" ]
}

@test "detect_default_branch returns master for repo with only master branch" {
  local master_dir
  master_dir="$(mktemp -d)"
  git -C "$master_dir" init -b master >/dev/null 2>&1
  git -C "$master_dir" config user.email "test@test.com"
  git -C "$master_dir" config user.name "Test"
  echo "init" > "$master_dir/README.md"
  git -C "$master_dir" add -A >/dev/null 2>&1
  git -C "$master_dir" commit -m "Initial commit" >/dev/null 2>&1

  local result
  result="$(detect_default_branch "$master_dir")"
  [ "$result" = "master" ]

  rm -rf "$master_dir"
}

# --- _resolve_checkout_target ---

@test "_resolve_checkout_target returns AUTOPILOT_TARGET_BRANCH when set" {
  AUTOPILOT_TARGET_BRANCH="develop"
  local result
  result="$(_resolve_checkout_target "$TEST_PROJECT_DIR")"
  [ "$result" = "develop" ]
}

@test "_resolve_checkout_target detects default branch when env unset" {
  unset AUTOPILOT_TARGET_BRANCH
  local result
  result="$(_resolve_checkout_target "$TEST_PROJECT_DIR")"
  [ "$result" = "main" ]
}

# --- commit_changes ---

@test "commit_changes stages and commits new files" {
  echo "new content" > "$TEST_PROJECT_DIR/new_file.txt"
  commit_changes "$TEST_PROJECT_DIR" "feat: add new file"
  local log_output
  log_output="$(git -C "$TEST_PROJECT_DIR" log --oneline -1)"
  [[ "$log_output" == *"feat: add new file"* ]]
}

@test "commit_changes stages and commits modifications" {
  echo "modified" > "$TEST_PROJECT_DIR/README.md"
  commit_changes "$TEST_PROJECT_DIR" "fix: update readme"
  local log_output
  log_output="$(git -C "$TEST_PROJECT_DIR" log --oneline -1)"
  [[ "$log_output" == *"fix: update readme"* ]]
}

@test "commit_changes returns 0 with warning when no changes" {
  run commit_changes "$TEST_PROJECT_DIR" "empty commit"
  [ "$status" -eq 0 ]
}

@test "commit_changes fails with empty message" {
  echo "change" > "$TEST_PROJECT_DIR/file.txt"
  run commit_changes "$TEST_PROJECT_DIR" ""
  [ "$status" -eq 1 ]
}

# --- get_head_sha ---

@test "get_head_sha returns current commit SHA" {
  local sha
  sha="$(get_head_sha "$TEST_PROJECT_DIR")"
  [ -n "$sha" ]
  # SHA is 40 hex characters.
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "get_head_sha changes after new commit" {
  local sha_before
  sha_before="$(get_head_sha "$TEST_PROJECT_DIR")"
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  commit_changes "$TEST_PROJECT_DIR" "test commit"
  local sha_after
  sha_after="$(get_head_sha "$TEST_PROJECT_DIR")"
  [ "$sha_before" != "$sha_after" ]
}

# --- push_branch ---

@test "push_branch pushes to bare remote" {
  # Create a bare repo as local remote.
  local bare_dir
  bare_dir="$(mktemp -d)"
  git init --bare "$bare_dir/remote.git" >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" remote add origin "$bare_dir/remote.git" 2>/dev/null || \
    git -C "$TEST_PROJECT_DIR" remote set-url origin "$bare_dir/remote.git"

  create_task_branch "$TEST_PROJECT_DIR" 8
  echo "push content" > "$TEST_PROJECT_DIR/pushed.txt"
  commit_changes "$TEST_PROJECT_DIR" "feat: content to push"

  push_branch "$TEST_PROJECT_DIR"

  # Verify branch exists on the remote.
  local remote_branches
  remote_branches="$(git -C "$bare_dir/remote.git" branch)"
  [[ "$remote_branches" == *"autopilot/task-8"* ]]

  rm -rf "$bare_dir"
}

@test "push_branch fails when no remote" {
  # Remove any remote.
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true

  run push_branch "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- create_task_pr (mocked gh) ---

@test "create_task_pr fails with empty title" {
  run create_task_pr "$TEST_PROJECT_DIR" 1 "" "body"
  [ "$status" -eq 1 ]
}

@test "create_task_pr calls gh with --title --head --base --repo and returns URL" {
  # Create mock gh that records args and returns a PR URL.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<MOCK
#!/usr/bin/env bash
echo "\$@" > "$mock_dir/gh_args.log"
echo "https://github.com/test/repo/pull/1"
MOCK
  chmod +x "$mock_dir/gh"

  # Set up remote URL.
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/test/repo.git" 2>/dev/null || true

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  local result
  result="$(create_task_pr "$TEST_PROJECT_DIR" 5 "My PR Title" "Body text")"
  [ "$result" = "https://github.com/test/repo/pull/1" ]

  # Verify expected arguments were passed.
  local args
  args="$(cat "$mock_dir/gh_args.log")"
  [[ "$args" == *"--title"* ]]
  [[ "$args" == *"My PR Title"* ]]
  [[ "$args" == *"--head"* ]]
  [[ "$args" == *"autopilot/task-5"* ]]
  [[ "$args" == *"--base"* ]]
  [[ "$args" == *"main"* ]]
  [[ "$args" == *"--repo"* ]]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

@test "create_task_pr returns failure when gh fails" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/gh"

  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/test/repo.git" 2>/dev/null || true

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  run create_task_pr "$TEST_PROJECT_DIR" 1 "Title" "Body"
  [ "$status" -eq 1 ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

# --- detect_task_pr (mocked gh) ---

@test "detect_task_pr returns PR URL and passes --repo flag" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<MOCK
#!/usr/bin/env bash
echo "\$@" > "$mock_dir/gh_args.log"
echo "https://github.com/test/repo/pull/42"
MOCK
  chmod +x "$mock_dir/gh"

  # Set up remote URL.
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/test/repo.git" 2>/dev/null || true

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  local result
  result="$(detect_task_pr "$TEST_PROJECT_DIR" 5)"
  [ "$result" = "https://github.com/test/repo/pull/42" ]

  # Verify expected arguments were passed.
  local args
  args="$(cat "$mock_dir/gh_args.log")"
  [[ "$args" == *"pr view"* ]]
  [[ "$args" == *"autopilot/task-5"* ]]
  [[ "$args" == *"--repo"* ]]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

@test "detect_task_pr returns failure when no PR exists" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/gh"

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  run detect_task_pr "$TEST_PROJECT_DIR" 5
  [ "$status" -eq 1 ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

# --- generate_pr_body (mocked claude) ---

@test "generate_pr_body returns fallback when no diff" {
  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "My Task")"
  [ "$result" = "Implementation for task 3." ]
}

@test "generate_pr_body uses claude to generate body from diff" {
  # Create a branch with changes to produce a diff.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  # Mock claude to return a PR body.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"## Summary\nAdded new code module with improvements."}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 1 "Add code module")"
  [[ "$result" == *"Added new code module"* ]]

  rm -rf "$mock_dir"
}

@test "generate_pr_body returns fallback on claude failure" {
  create_task_branch "$TEST_PROJECT_DIR" 2
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that fails.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 2 "Task")"
  [ "$result" = "Implementation for task 2." ]

  rm -rf "$mock_dir"
}

@test "generate_pr_body returns fallback on empty claude response" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that returns empty result.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"cost_usd":0.01}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "Task")"
  [ "$result" = "Implementation for task 3." ]

  rm -rf "$mock_dir"
}

# --- _build_pr_body_prompt ---

@test "_build_pr_body_prompt includes task number and title" {
  local result
  result="$(_build_pr_body_prompt 5 "Add auth" "diff content")"
  [[ "$result" == *"Task 5"* ]]
  [[ "$result" == *"Add auth"* ]]
}

@test "_build_pr_body_prompt includes diff content" {
  local result
  result="$(_build_pr_body_prompt 1 "Title" "+new line added")"
  [[ "$result" == *"+new line added"* ]]
}

# --- build_pr_title ---

@test "build_pr_title extracts title from tasks.md header" {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'EOF'
# Project Tasks

## Task 1: Project scaffold and Makefile

Create the initial structure.

## Task 2: Config loading

Implement config parser.
EOF

  local result
  result="$(build_pr_title "$TEST_PROJECT_DIR" 1)"
  [ "$result" = "Task 1: Project scaffold and Makefile" ]
}

@test "build_pr_title handles special characters in title" {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'EOF'
## Task 5: Add "quotes" & ampersands (with parens)

Details here.
EOF

  local result
  result="$(build_pr_title "$TEST_PROJECT_DIR" 5)"
  [ "$result" = 'Task 5: Add "quotes" & ampersands (with parens)' ]
}

@test "build_pr_title falls back to commit message when header missing" {
  # No tasks.md file — force fallback.
  create_task_branch "$TEST_PROJECT_DIR" 9
  echo "code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: initial implementation" >/dev/null 2>&1

  local result
  result="$(build_pr_title "$TEST_PROJECT_DIR" 9)"
  [ "$result" = "feat: initial implementation" ]
}

@test "build_pr_title falls back when task number not found in file" {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'EOF'
## Task 1: First task

Content.

## Task 2: Second task

Content.
EOF

  # Task 99 doesn't exist; need commits for fallback.
  create_task_branch "$TEST_PROJECT_DIR" 99
  echo "work" > "$TEST_PROJECT_DIR/work.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "chore: some work" >/dev/null 2>&1

  local result
  result="$(build_pr_title "$TEST_PROJECT_DIR" 99)"
  [ "$result" = "chore: some work" ]
}

# --- _parse_title_from_heading ---

@test "_parse_title_from_heading strips ## Task prefix" {
  local result
  result="$(_parse_title_from_heading "## Task 3: State management")"
  [ "$result" = "Task 3: State management" ]
}

@test "_parse_title_from_heading converts ### PR prefix to Task" {
  local result
  result="$(_parse_title_from_heading "### PR 2: Config system")"
  [ "$result" = "Task 2: Config system" ]
}

@test "_parse_title_from_heading preserves special characters" {
  local result
  result="$(_parse_title_from_heading "## Task 10: Handle \$PATH & \"env\" vars")"
  [ "$result" = 'Task 10: Handle $PATH & "env" vars' ]
}
