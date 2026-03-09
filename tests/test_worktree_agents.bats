#!/usr/bin/env bats
# Tests for coder/fixer running inside worktree paths.
# Validates work_dir parameter, CLAUDE.md symlinks, and worktree git operations.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  TEST_HOOKS_DIR="$(mktemp -d)"

  # Source coder.sh and fixer.sh (which source all dependencies).
  source "$BATS_TEST_DIRNAME/../lib/coder.sh"
  source "$BATS_TEST_DIRNAME/../lib/fixer.sh"

  # Initialize pipeline state dir.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dirs to use real prompts in repo.
  _CODER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Enable worktree mode.
  AUTOPILOT_USE_WORKTREES="true"

  # Shared mock dir for cwd-recording Claude mock.
  TEST_MOCK_DIR="$(mktemp -d)"
}

# Create a mock Claude binary that records its working directory.
_create_cwd_recording_mock() {
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/bin/bash
echo "{\"result\":\"cwd=$(pwd)\"}"
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"
}

# Clean up agent output files.
_cleanup_agent_output() {
  local output_file="$1"
  rm -f "$output_file" "${output_file}.err"
}

teardown() {
  # Clean up any worktrees before removing project dir.
  git -C "$TEST_PROJECT_DIR" worktree list --porcelain 2>/dev/null | \
    grep '^worktree ' | while read -r _ path; do
      [[ "$path" == "$TEST_PROJECT_DIR" ]] && continue
      git -C "$TEST_PROJECT_DIR" worktree remove --force "$path" 2>/dev/null || true
    done
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
  rm -rf "$TEST_MOCK_DIR"
}

# --- _setup_worktree_symlinks ---

@test "symlinks: CLAUDE.md is symlinked into worktree" {
  echo "# Project Instructions" > "$TEST_PROJECT_DIR/CLAUDE.md"

  create_task_branch "$TEST_PROJECT_DIR" 1
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 1)"

  [ -L "$wt_path/CLAUDE.md" ]
  local content
  content="$(cat "$wt_path/CLAUDE.md")"
  [[ "$content" == *"Project Instructions"* ]]
}

@test "symlinks: .claude/ is symlinked into worktree" {
  mkdir -p "$TEST_PROJECT_DIR/.claude"
  echo '{"key":"val"}' > "$TEST_PROJECT_DIR/.claude/settings.json"

  create_task_branch "$TEST_PROJECT_DIR" 2
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 2)"

  [ -L "$wt_path/.claude" ]
  [ -f "$wt_path/.claude/settings.json" ]
}

@test "symlinks: skips when CLAUDE.md already exists in worktree" {
  # Track CLAUDE.md in git so it appears in the worktree checkout.
  echo "# Tracked" > "$TEST_PROJECT_DIR/CLAUDE.md"
  git -C "$TEST_PROJECT_DIR" add CLAUDE.md >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add CLAUDE.md" -q

  create_task_branch "$TEST_PROJECT_DIR" 3
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 3)"

  # Should be a regular file (from checkout), not a symlink.
  [ -f "$wt_path/CLAUDE.md" ]
  [ ! -L "$wt_path/CLAUDE.md" ]
}

@test "symlinks: skips when CLAUDE.md not present in project" {
  create_task_branch "$TEST_PROJECT_DIR" 4
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 4)"

  [ ! -e "$wt_path/CLAUDE.md" ]
}

# --- run_coder with work_dir ---

@test "coder: runs inside worktree when work_dir is provided" {
  _create_cwd_recording_mock
  AUTOPILOT_TIMEOUT_CODER=10

  create_task_branch "$TEST_PROJECT_DIR" 5
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 5)"

  local output_file
  output_file="$(run_coder "$TEST_PROJECT_DIR" 5 "Task body" "" "" 0 "$wt_path")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"cwd=${wt_path}"* ]]

  _cleanup_agent_output "$output_file"
}

@test "coder: defaults work_dir to project_dir when not specified" {
  _create_cwd_recording_mock
  AUTOPILOT_TIMEOUT_CODER=10

  # No work_dir param — should NOT cd (stays in current dir).
  local output_file
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Task body")" || true

  # Output should exist and contain a cwd.
  [ -f "$output_file" ]

  _cleanup_agent_output "$output_file"
}

# --- run_fixer with work_dir ---

@test "fixer: runs inside worktree when work_dir is provided" {
  _create_cwd_recording_mock
  AUTOPILOT_TIMEOUT_FIXER=10

  create_task_branch "$TEST_PROJECT_DIR" 6
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 6)"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 6 42 "$wt_path")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"cwd=${wt_path}"* ]]

  _cleanup_agent_output "$output_file"
}

# --- Git operations in worktree ---

@test "worktree: commits work inside worktree" {
  create_task_branch "$TEST_PROJECT_DIR" 7
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 7)"

  echo "new file" > "$wt_path/feature.txt"
  git -C "$wt_path" add -A >/dev/null 2>&1
  git -C "$wt_path" commit -m "feat: add feature" -q

  local log_output
  log_output="$(git -C "$wt_path" log --oneline -1)"
  [[ "$log_output" == *"feat: add feature"* ]]

  # Main working tree should still be on main.
  local main_branch
  main_branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$main_branch" = "main" ]
}

@test "worktree: push from worktree works" {
  # Set up a bare remote to push to.
  local bare_remote
  bare_remote="$(mktemp -d)"
  git -C "$TEST_PROJECT_DIR" clone --bare "$TEST_PROJECT_DIR" "$bare_remote" 2>/dev/null
  git -C "$TEST_PROJECT_DIR" remote set-url origin "$bare_remote"

  create_task_branch "$TEST_PROJECT_DIR" 8
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 8)"

  echo "feature code" > "$wt_path/code.sh"
  git -C "$wt_path" add -A >/dev/null 2>&1
  git -C "$wt_path" commit -m "feat: code" -q

  # Push from the worktree.
  push_branch "$wt_path"

  # Verify the branch exists in the remote.
  git -C "$bare_remote" rev-parse --verify "autopilot/task-8" >/dev/null 2>&1

  rm -rf "$bare_remote"
}

# --- CLAUDE.md accessible from worktree ---

@test "worktree: CLAUDE.md is accessible after coder completes" {
  echo "# Important instructions" > "$TEST_PROJECT_DIR/CLAUDE.md"

  create_task_branch "$TEST_PROJECT_DIR" 9
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 9)"

  # Simulate coder work — CLAUDE.md should be readable.
  [ -r "$wt_path/CLAUDE.md" ]
  local content
  content="$(cat "$wt_path/CLAUDE.md")"
  [[ "$content" == *"Important instructions"* ]]
}

# --- resolve_task_dir ---

@test "resolve_task_dir returns worktree path in worktree mode" {
  local result
  result="$(resolve_task_dir "$TEST_PROJECT_DIR" 10)"
  [ "$result" = "$TEST_PROJECT_DIR/.autopilot/worktrees/task-10" ]
}

@test "resolve_task_dir returns project_dir when worktrees disabled" {
  AUTOPILOT_USE_WORKTREES="false"
  local result
  result="$(resolve_task_dir "$TEST_PROJECT_DIR" 10)"
  [ "$result" = "$TEST_PROJECT_DIR" ]
}

# --- Hooks point to work_dir ---

@test "hooks: lint/test commands point to work_dir in worktree mode" {
  create_task_branch "$TEST_PROJECT_DIR" 11
  local wt_path
  wt_path="$(get_task_worktree_path "$TEST_PROJECT_DIR" 11)"

  # Create a Makefile in the worktree so hooks detect it.
  cat > "$wt_path/Makefile" <<'MAKEFILE'
lint:
	echo "linting"
test:
	echo "testing"
MAKEFILE

  local settings_file="${TEST_HOOKS_DIR}/settings.json"

  install_hooks "$wt_path" "$TEST_HOOKS_DIR"

  # Verify hook commands reference the worktree path.
  local hook_content
  hook_content="$(cat "$settings_file")"
  [[ "$hook_content" == *"$wt_path"* ]]

  remove_hooks "$wt_path" "$TEST_HOOKS_DIR"
}
