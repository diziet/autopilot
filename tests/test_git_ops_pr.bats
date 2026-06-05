#!/usr/bin/env bats
# Tests for lib/git-ops.sh — commit, push, PR creation/detection, title building.
# Split from test_git_ops.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/git_ops_setup

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
  # Copy pre-built bare remote template instead of creating from scratch.
  local bare_dir
  bare_dir="$BATS_TEST_TMPDIR/bare_push"
  _fast_copy "${_GITOPS_TEMPLATE_DIR}/bare" "$bare_dir"
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
  mock_dir="$BATS_TEST_TMPDIR/mock_gh_create"
  mkdir -p "$mock_dir"
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
}

@test "create_task_pr returns failure when gh fails" {
  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_gh_create_fail"
  mkdir -p "$mock_dir"
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
}

# --- detect_task_pr (mocked gh) ---

@test "detect_task_pr returns PR URL and passes --repo flag" {
  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_gh_detect"
  mkdir -p "$mock_dir"
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
}

@test "detect_task_pr returns failure when no PR exists" {
  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_gh_detect_fail"
  mkdir -p "$mock_dir"
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
  mock_dir="$BATS_TEST_TMPDIR/mock_claude_body"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"## Summary\nAdded new code module with improvements."}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 1 "Add code module")"
  [[ "$result" == *"Added new code module"* ]]
}

@test "generate_pr_body returns fallback on claude failure" {
  create_task_branch "$TEST_PROJECT_DIR" 2
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that fails.
  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_claude_fail"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 2 "Task")"
  [ "$result" = "Implementation for task 2." ]
}

@test "generate_pr_body returns fallback on empty claude response" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that returns empty result.
  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_claude_empty"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"cost_usd":0.01}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "Task")"
  [ "$result" = "Implementation for task 3." ]
}

# --- generate_pr_body: model footer ---

# Mock claude returning a fixed body, used by footer tests.
_setup_mock_claude_body() {
  local mock_dir="$BATS_TEST_TMPDIR/mock_claude_footer"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"Body text."}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
}

@test "generate_pr_body appends coder resolved model footer" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo '{"result":"x","modelUsage":{"claude-opus-4-8":{}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-task-1.json"

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 1 "Add code module")"
  [[ "$result" == *"Body text."* ]]
  [[ "$result" == *"_Implemented by claude-opus-4-8 via autopilot._"* ]]
}

@test "generate_pr_body footer uses primary model from multi-key modelUsage" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  # opus is the primary (first) model; haiku is a subagent helper. haiku sorts
  # first alphabetically, so a joined footer would mislead — expect opus alone.
  echo '{"result":"x","modelUsage":{"claude-opus-4-8":{},"claude-haiku-4-5":{}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-task-1.json"

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 1 "Add code module")"
  [[ "$result" == *"_Implemented by claude-opus-4-8 via autopilot._"* ]]
  [[ "$result" != *"claude-haiku-4-5"* ]]
}

@test "generate_pr_body footer falls back to configured model alias" {
  create_task_branch "$TEST_PROJECT_DIR" 2
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # No coder-task-2.json exists — fall back to configured alias.
  AUTOPILOT_CLAUDE_MODEL="opus"

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 2 "Task")"
  [[ "$result" == *"_Implemented by opus via autopilot._"* ]]
}

@test "generate_pr_body omits footer when no model available" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # No coder JSON and no configured alias.
  AUTOPILOT_CLAUDE_MODEL=""

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "Task")"
  [[ "$result" == *"Body text."* ]]
  [[ "$result" != *"via autopilot"* ]]
}

@test "generate_pr_body footer reads coder JSON from project dir not worktree" {
  # Reproduces the bug: the pipeline passes the worktree (task_dir) as the diff
  # dir, but the coder JSON lives only under the main project dir. The footer
  # must read it from the project dir, not the worktree.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  # Coder JSON exists only under the project dir, never the worktree.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo '{"result":"x","modelUsage":{"claude-opus-4-8":{}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-task-1.json"

  # Configured alias differs from the resolved model — proves the footer uses
  # the resolved model, not the fallback alias.
  AUTOPILOT_CLAUDE_MODEL="opus"

  # Distinct worktree path for the diff; no coder JSON under it.
  local worktree_dir="$BATS_TEST_TMPDIR/worktree"
  git -C "$TEST_PROJECT_DIR" worktree add -q --detach "$worktree_dir" \
    "$(build_branch_name 1)" >/dev/null 2>&1

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$worktree_dir" 1 "Add code module" \
    "$TEST_PROJECT_DIR")"
  [[ "$result" == *"_Implemented by claude-opus-4-8 via autopilot._"* ]]
  [[ "$result" != *"_Implemented by opus via autopilot._"* ]]
}

@test "generate_pr_body footer falls back to alias when no coder JSON in project dir" {
  # task_dir worktree differs from project_dir, and no coder JSON exists under
  # the project dir — the footer falls back to the configured alias.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  AUTOPILOT_CLAUDE_MODEL="opus"

  local worktree_dir="$BATS_TEST_TMPDIR/worktree_nojson"
  git -C "$TEST_PROJECT_DIR" worktree add -q --detach "$worktree_dir" \
    "$(build_branch_name 1)" >/dev/null 2>&1

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$worktree_dir" 1 "Add code module" \
    "$TEST_PROJECT_DIR")"
  [[ "$result" == *"_Implemented by opus via autopilot._"* ]]
}

@test "generate_pr_body omits footer under worktree call shape when no model" {
  # Same as the no-model case, but exercised under the new call shape: a
  # distinct worktree task_dir (arg 1) and a separate coder_project_dir (arg 4),
  # neither holding a coder JSON, with no configured alias — footer is omitted.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  # No coder JSON under the project dir and no configured alias.
  AUTOPILOT_CLAUDE_MODEL=""

  local worktree_dir="$BATS_TEST_TMPDIR/worktree_nomodel"
  git -C "$TEST_PROJECT_DIR" worktree add -q --detach "$worktree_dir" \
    "$(build_branch_name 1)" >/dev/null 2>&1

  _setup_mock_claude_body

  local result
  result="$(generate_pr_body "$worktree_dir" 1 "Add code module" \
    "$TEST_PROJECT_DIR")"
  [[ "$result" == *"Body text."* ]]
  [[ "$result" != *"via autopilot"* ]]
}

# Mock claude that captures the prompt it received (which embeds the diff) to a
# file, so tests can assert which directory the diff was sourced from.
_setup_mock_claude_capture() {
  local capture_file="$1"
  local mock_dir="$BATS_TEST_TMPDIR/mock_claude_capture"
  mkdir -p "$mock_dir"
  # Unquoted heredoc so $capture_file is interpolated; bash vars are escaped.
  cat > "$mock_dir/claude" <<MOCK
#!/usr/bin/env bash
# The prompt (with the embedded diff) is the last positional argument.
prompt=""
for prompt in "\$@"; do :; done
printf '%s' "\$prompt" > "$capture_file"
echo '{"result":"Body text."}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
}

@test "generate_pr_body diff is read from the worktree not the coder project dir" {
  # Pins the worktree-diff behavior after the signature change: the diff/summary
  # must come from the task_dir worktree (arg 1), never from coder_project_dir
  # (arg 4), which is only consulted for the model footer.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "base" > "$TEST_PROJECT_DIR/base.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Base commit" >/dev/null 2>&1

  # Worktree is created at the current branch tip, then the two dirs diverge.
  local worktree_dir="$BATS_TEST_TMPDIR/worktree_diff"
  git -C "$TEST_PROJECT_DIR" worktree add -q --detach "$worktree_dir" \
    "$(build_branch_name 1)" >/dev/null 2>&1

  # Commit a marker ONLY in the coder/project dir — must not appear in the diff.
  echo "coder content CODER_DIFF_MARKER" > "$TEST_PROJECT_DIR/coder_only.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Coder only" >/dev/null 2>&1

  # Commit a marker ONLY in the worktree — must appear in the diff.
  echo "worktree content WORKTREE_DIFF_MARKER" > "$worktree_dir/worktree_only.sh"
  git -C "$worktree_dir" add -A >/dev/null 2>&1
  git -C "$worktree_dir" commit -m "Worktree only" >/dev/null 2>&1

  local capture_file="$BATS_TEST_TMPDIR/captured_prompt.txt"
  _setup_mock_claude_capture "$capture_file"

  generate_pr_body "$worktree_dir" 1 "Add code module" "$TEST_PROJECT_DIR" \
    >/dev/null

  # The diff fed to claude reflects the worktree's commits, not the coder dir's.
  grep -q "WORKTREE_DIFF_MARKER" "$capture_file"
  ! grep -q "CODER_DIFF_MARKER" "$capture_file"
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
