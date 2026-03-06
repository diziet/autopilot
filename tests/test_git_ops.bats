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

# --- delete_task_branch ---

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
