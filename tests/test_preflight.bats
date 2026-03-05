#!/usr/bin/env bats
# Tests for lib/preflight.sh — preflight validation checks.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Create a valid git repo in the test project dir.
  git -C "$TEST_PROJECT_DIR" init -q
  touch "$TEST_PROJECT_DIR/dummy.txt"
  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -q -m "initial"

  # Create required project files.
  echo "# Tasks" > "$TEST_PROJECT_DIR/tasks.md"
  echo "## Task 1" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "# Project CLAUDE.md" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create mock commands that succeed by default.
  _create_mock "$MOCK_BIN/claude" 0
  _create_mock "$MOCK_BIN/gh" 0
  _create_mock "$MOCK_BIN/jq" 0
  _create_mock "$MOCK_BIN/git" 0
  _create_mock "$MOCK_BIN/timeout" 0

  # Put mock bin first in PATH so mocks override real commands,
  # but keep real git for the actual git repo checks.
  REAL_GIT="$(command -v git)"
  REAL_JQ="$(command -v jq)"
  OLD_PATH="$PATH"

  # Source preflight.sh (which sources config, state, tasks).
  source "$BATS_TEST_DIRNAME/../lib/preflight.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR" "$MOCK_BIN"
}

# Create a mock executable that exits with a given code.
_create_mock() {
  local path="$1"
  local exit_code="${2:-0}"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
exit $exit_code
MOCK
  chmod +x "$path"
}

# Create a gh mock that simulates auth status.
_create_gh_mock() {
  local exit_code="${1:-0}"
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "auth" && "\$2" == "status" ]]; then
  exit $exit_code
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/gh"
}

# --- _get_install_hint ---

@test "_get_install_hint returns macOS hint for timeout" {
  local hint
  hint="$(_get_install_hint "timeout")"
  [[ "$hint" == *"brew install coreutils"* ]]
  [[ "$hint" == *"macOS"* ]]
}

@test "_get_install_hint returns hint for gh" {
  local hint
  hint="$(_get_install_hint "gh")"
  [[ "$hint" == *"brew install gh"* ]]
}

@test "_get_install_hint returns hint for jq" {
  local hint
  hint="$(_get_install_hint "jq")"
  [[ "$hint" == *"brew install jq"* ]]
}

@test "_get_install_hint returns hint for git" {
  local hint
  hint="$(_get_install_hint "git")"
  [[ "$hint" == *"xcode-select"* ]]
}

@test "_get_install_hint returns hint for claude" {
  local hint
  hint="$(_get_install_hint "claude")"
  [[ "$hint" == *"anthropic"* ]]
}

@test "_get_install_hint returns generic hint for unknown command" {
  local hint
  hint="$(_get_install_hint "foobar")"
  [[ "$hint" == *"Install foobar"* ]]
}

# --- _check_command ---

@test "_check_command finds existing command" {
  _check_command "bash"
}

@test "_check_command fails for nonexistent command" {
  ! _check_command "nonexistent_command_xyz_12345"
}

# --- check_dependencies ---

@test "check_dependencies passes when all deps available" {
  # All real commands should be on PATH in CI/dev.
  AUTOPILOT_CLAUDE_CMD="bash"
  check_dependencies "$TEST_PROJECT_DIR"
}

@test "check_dependencies fails when claude command missing" {
  AUTOPILOT_CLAUDE_CMD="nonexistent_claude_xyz"
  run check_dependencies "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "check_dependencies uses AUTOPILOT_CLAUDE_CMD from config" {
  # Create a custom claude mock.
  local custom_claude
  custom_claude="$(mktemp)"
  chmod +x "$custom_claude"
  echo '#!/usr/bin/env bash' > "$custom_claude"
  echo 'exit 0' >> "$custom_claude"

  AUTOPILOT_CLAUDE_CMD="$custom_claude"
  check_dependencies "$TEST_PROJECT_DIR"
  rm -f "$custom_claude"
}

@test "check_dependencies reports all missing deps not just first" {
  # Override check to capture log output.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"

  AUTOPILOT_CLAUDE_CMD="nonexistent_claude_xyz_1"
  run check_dependencies "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]

  # Should have logged the missing claude command.
  local log_content
  log_content="$(cat "$log_file")"
  [[ "$log_content" == *"nonexistent_claude_xyz_1"* ]]
}

# --- check_git_repo ---

@test "check_git_repo passes for valid git repo" {
  check_git_repo "$TEST_PROJECT_DIR"
}

@test "check_git_repo fails for non-git directory" {
  local non_git_dir
  non_git_dir="$(mktemp -d)"
  run check_git_repo "$non_git_dir"
  [ "$status" -eq 1 ]
  rm -rf "$non_git_dir"
}

# --- check_clean_worktree ---

@test "check_clean_worktree passes for clean repo" {
  check_clean_worktree "$TEST_PROJECT_DIR"
}

@test "check_clean_worktree fails with unstaged changes" {
  echo "modified" >> "$TEST_PROJECT_DIR/dummy.txt"
  run check_clean_worktree "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "check_clean_worktree fails with staged uncommitted changes" {
  echo "staged" >> "$TEST_PROJECT_DIR/dummy.txt"
  git -C "$TEST_PROJECT_DIR" add dummy.txt
  run check_clean_worktree "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- check_gh_auth ---

@test "check_gh_auth passes when authenticated" {
  # Real gh should be authenticated in dev/CI.
  # Skip if gh is not available.
  command -v gh >/dev/null 2>&1 || skip "gh not installed"
  gh auth status >/dev/null 2>&1 || skip "gh not authenticated"
  check_gh_auth "$TEST_PROJECT_DIR"
}

@test "check_gh_auth fails when not authenticated" {
  # Create a mock gh that fails auth.
  _create_gh_mock 1
  PATH="$MOCK_BIN:$OLD_PATH"
  run check_gh_auth "$TEST_PROJECT_DIR"
  PATH="$OLD_PATH"
  [ "$status" -eq 1 ]
}

# --- check_tasks_file ---

@test "check_tasks_file passes when tasks.md exists" {
  check_tasks_file "$TEST_PROJECT_DIR"
}

@test "check_tasks_file passes with configured AUTOPILOT_TASKS_FILE" {
  echo "# Guide" > "$TEST_PROJECT_DIR/myguide.md"
  echo "## Task 1" >> "$TEST_PROJECT_DIR/myguide.md"
  AUTOPILOT_TASKS_FILE="myguide.md"
  check_tasks_file "$TEST_PROJECT_DIR"
}

@test "check_tasks_file fails when no tasks file found" {
  rm -f "$TEST_PROJECT_DIR/tasks.md"
  run check_tasks_file "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "check_tasks_file fails when configured file does not exist" {
  AUTOPILOT_TASKS_FILE="nonexistent.md"
  run check_tasks_file "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- check_claude_md ---

@test "check_claude_md passes when CLAUDE.md exists" {
  check_claude_md "$TEST_PROJECT_DIR"
}

@test "check_claude_md fails when CLAUDE.md missing" {
  rm -f "$TEST_PROJECT_DIR/CLAUDE.md"
  run check_claude_md "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- is_interactive ---

@test "is_interactive returns based on stdin TTY status" {
  # When piped (as in bats), stdin is not a TTY.
  run is_interactive
  [ "$status" -eq 1 ]
}

# --- check_noninteractive_permissions ---

@test "check_noninteractive_permissions passes in interactive mode" {
  # Override is_interactive to simulate TTY.
  is_interactive() { return 0; }
  AUTOPILOT_CLAUDE_FLAGS=""
  check_noninteractive_permissions "$TEST_PROJECT_DIR"
}

@test "check_noninteractive_permissions passes with skip-permissions flag in non-interactive" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
  check_noninteractive_permissions "$TEST_PROJECT_DIR"
}

@test "check_noninteractive_permissions passes with flag among others" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS="--verbose --dangerously-skip-permissions --debug"
  check_noninteractive_permissions "$TEST_PROJECT_DIR"
}

@test "check_noninteractive_permissions fails without flag in non-interactive" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS=""
  run check_noninteractive_permissions "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "check_noninteractive_permissions logs CRITICAL on failure" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS=""
  run check_noninteractive_permissions "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"CRITICAL"* ]]
  [[ "$log_content" == *"dangerously-skip-permissions"* ]]
}

@test "check_noninteractive_permissions fails with unrelated flags" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS="--verbose --debug"
  run check_noninteractive_permissions "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- run_preflight ---

@test "run_preflight passes with all conditions met and interactive" {
  # Override is_interactive to simulate TTY.
  is_interactive() { return 0; }
  run_preflight "$TEST_PROJECT_DIR"
}

@test "run_preflight logs start and completion" {
  is_interactive() { return 0; }
  run_preflight "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Running preflight checks"* ]]
  [[ "$log_content" == *"Preflight checks passed"* ]]
}

@test "run_preflight fails without CLAUDE.md" {
  is_interactive() { return 0; }
  rm -f "$TEST_PROJECT_DIR/CLAUDE.md"
  run run_preflight "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "run_preflight fails without tasks file" {
  is_interactive() { return 0; }
  rm -f "$TEST_PROJECT_DIR/tasks.md"
  run run_preflight "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "run_preflight fails in non-interactive without permission flag" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS=""
  run run_preflight "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "run_preflight passes in non-interactive with permission flag" {
  is_interactive() { return 1; }
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
  run_preflight "$TEST_PROJECT_DIR"
}

@test "run_preflight continues with dirty worktree warning" {
  is_interactive() { return 0; }
  echo "dirty" >> "$TEST_PROJECT_DIR/dummy.txt"
  # Should still pass — dirty worktree is a warning, not fatal.
  run_preflight "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"dirty working tree"* ]]
}

@test "run_preflight fails for non-git directory" {
  is_interactive() { return 0; }
  local non_git
  non_git="$(mktemp -d)"
  echo "# Tasks" > "$non_git/tasks.md"
  echo "## Task 1" >> "$non_git/tasks.md"
  echo "# CLAUDE" > "$non_git/CLAUDE.md"
  mkdir -p "$non_git/.autopilot/logs"

  run run_preflight "$non_git"
  [ "$status" -eq 1 ]
  rm -rf "$non_git"
}

@test "run_preflight fails when gh auth fails" {
  is_interactive() { return 0; }
  _create_gh_mock 1
  PATH="$MOCK_BIN:$OLD_PATH"
  run run_preflight "$TEST_PROJECT_DIR"
  PATH="$OLD_PATH"
  [ "$status" -eq 1 ]
}
