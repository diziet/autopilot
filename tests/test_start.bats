#!/usr/bin/env bats
# Tests for bin/autopilot-start — validate and start the pipeline.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  UTILS_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Symlink essential system commands into an isolated utils dir.
  local cmd
  for cmd in bash basename cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id awk wc ps; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Create mock commands for prerequisites.
  _create_mock "claude"
  _create_mock "jq"
  _create_mock "git"
  _create_mock "timeout"

  # Mock gh and claude to succeed by default.
  _mock_gh 0 0
  _mock_claude 0

  # Create a wrapper for autopilot-doctor that calls the real binary.
  cat > "$MOCK_BIN/autopilot-doctor" << WRAPPER
#!/usr/bin/env bash
exec "$REPO_DIR/bin/autopilot-doctor" "\$@"
WRAPPER
  chmod +x "$MOCK_BIN/autopilot-doctor"

  # Set HOME to temp dir for account detection.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"

  # Set up a valid project directory with PAUSE file.
  mkdir -p "$TEST_DIR/project/.autopilot"
  touch "$TEST_DIR/project/.autopilot/PAUSE"
  echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$TEST_DIR/project/autopilot.conf"
  echo '.autopilot/' > "$TEST_DIR/project/.gitignore"
  cat > "$TEST_DIR/project/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS
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

# Run autopilot-start with isolated PATH.
_run_start() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-start" "$TEST_DIR/project"
}

# --- Start removes PAUSE after doctor passes ---

@test "start: removes PAUSE file when doctor passes" {
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  _run_start
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Pipeline started"* ]]
  [[ "$output" == *"tail -f .autopilot/logs/pipeline.log"* ]]
}

# --- Start aborts when doctor fails ---

@test "start: aborts when doctor fails (missing config)" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_start
  echo "$output"
  [ "$status" -eq 1 ]
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Start aborted"* ]]
}

@test "start: aborts when doctor fails (missing tasks)" {
  rm -f "$TEST_DIR/project/tasks.md"
  _run_start
  echo "$output"
  [ "$status" -eq 1 ]
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Start aborted"* ]]
}

# --- Idempotent when already running ---

@test "start: prints already running when no PAUSE file" {
  rm -f "$TEST_DIR/project/.autopilot/PAUSE"
  _run_start
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipeline is already running."* ]]
}

# --- Help flag ---

@test "start: --help prints usage" {
  run "$REPO_DIR/bin/autopilot-start" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"autopilot-start"* ]]
}

# --- Unknown option ---

@test "start: rejects unknown options" {
  run "$REPO_DIR/bin/autopilot-start" --bogus
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

# --- Invalid project directory ---

@test "start: fails for nonexistent project directory" {
  run "$REPO_DIR/bin/autopilot-start" "/tmp/nonexistent-dir-xyz"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"project directory not found"* ]]
}
