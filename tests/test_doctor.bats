#!/usr/bin/env bats
# Tests for bin/autopilot-doctor — pre-run setup validation command.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  UTILS_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Create a utils dir with essential system commands (symlinked).
  local cmd
  for cmd in bash basename cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id awk wc; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Create mock commands for all prerequisites.
  _create_mock "claude"
  _create_mock "jq"
  _create_mock "git"
  _create_mock "timeout"

  # Mock gh and claude to succeed by default.
  _mock_gh 0 0
  _mock_claude 0

  # Set HOME to temp dir for account detection tests.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"

  # Set up a valid project directory.
  mkdir -p "$TEST_DIR/project"
  echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$TEST_DIR/project/autopilot.conf"
  echo '.autopilot/' > "$TEST_DIR/project/.gitignore"
  cat > "$TEST_DIR/project/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS

  cd "$TEST_DIR/project"
}

teardown() {
  PATH="$OLD_PATH"
  export HOME="$OLD_HOME"
  rm -rf "$TEST_DIR" "$MOCK_BIN" "$UTILS_BIN"
}

# Create a simple mock that exits 0.
_create_mock() {
  cat > "$MOCK_BIN/$1" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/$1"
}

# Create a gh mock with configurable auth and repo-view exit codes.
_mock_gh() {
  local auth_exit="${1:-0}"
  local repo_exit="${2:-0}"
  cat > "$MOCK_BIN/gh" << MOCK
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) echo "Logged in to github.com account testuser"; exit $auth_exit ;;
  *"repo view"*) echo '{"name":"test"}'; exit $repo_exit ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
}

# Create a claude mock with configurable exit code.
_mock_claude() {
  local exit_code="${1:-0}"
  cat > "$MOCK_BIN/claude" << MOCK
#!/usr/bin/env bash
echo '{"result":"OK"}'
exit $exit_code
MOCK
  chmod +x "$MOCK_BIN/claude"
}

# Run autopilot-doctor with isolated PATH.
_run_doctor() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-doctor" "$TEST_DIR/project"
}

# --- All checks pass ---

@test "doctor: passes when everything is configured" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
}

# --- Prerequisite failures ---

@test "doctor: fails when claude is missing" {
  rm -f "$MOCK_BIN/claude"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] claude not found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

@test "doctor: fails when gh is missing" {
  rm -f "$MOCK_BIN/gh"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] gh not found"* ]]
}

@test "doctor: fails when jq is missing" {
  rm -f "$MOCK_BIN/jq"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] jq not found"* ]]
}

@test "doctor: fails when git is missing" {
  rm -f "$MOCK_BIN/git"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] git not found"* ]]
}

@test "doctor: fails when timeout is missing with coreutils hint" {
  rm -f "$MOCK_BIN/timeout"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] timeout not found"* ]]
  [[ "$output" == *"brew install coreutils"* ]]
}

# --- gh auth failure ---

@test "doctor: fails when gh auth is not configured" {
  _mock_gh 1 0
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] gh not authenticated"* ]]
  [[ "$output" == *"gh auth login"* ]]
}

# --- Tasks file failures ---

@test "doctor: fails when tasks file is missing" {
  rm -f "$TEST_DIR/project/tasks.md"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] No tasks file found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

@test "doctor: fails when tasks file has no Task headings" {
  echo "# Just a title" > "$TEST_DIR/project/tasks.md"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Tasks file"* ]]
  [[ "$output" == *"no '## Task N' headings"* ]]
}

# --- Config failures ---

@test "doctor: fails when autopilot.conf is missing" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] autopilot.conf not found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

# --- Gitignore failures ---

@test "doctor: fails when .gitignore is missing" {
  rm -f "$TEST_DIR/project/.gitignore"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] .gitignore not found"* ]]
}

@test "doctor: fails when .autopilot/ not in .gitignore" {
  echo "node_modules/" > "$TEST_DIR/project/.gitignore"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] .autopilot/ not in .gitignore"* ]]
}

# --- GitHub remote failure ---

@test "doctor: fails when GitHub remote is not reachable" {
  _mock_gh 0 1
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] GitHub remote not reachable"* ]]
}

# --- Claude smoke test failure ---

@test "doctor: fails when Claude smoke test fails" {
  _mock_claude 1
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Claude"* ]]
  [[ "$output" == *"API not responding"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

# --- Two-account detection ---

@test "doctor: detects two-account setup" {
  mkdir -p "$HOME/.claude-account1"
  mkdir -p "$HOME/.claude-account2"
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Two-account setup detected"* ]]
  [[ "$output" == *"Claude account 1"* ]]
  [[ "$output" == *"Claude account 2"* ]]
}

@test "doctor: warns when only one account detected" {
  mkdir -p "$HOME/.claude-account1"
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] Only one Claude account detected"* ]]
}

@test "doctor: single account with default config" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default config"* ]]
}

# --- Help flag ---

@test "doctor: --help prints usage" {
  run "$REPO_DIR/bin/autopilot-doctor" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"autopilot-doctor"* ]]
}

# --- Permissions flag warning ---

@test "doctor: warns when --dangerously-skip-permissions not set" {
  echo "# empty config" > "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"dangerously-skip-permissions"* ]]
}

@test "doctor: skips permissions check when config not loaded" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [[ "$output" == *"permissions check skipped — config not loaded"* ]]
}
