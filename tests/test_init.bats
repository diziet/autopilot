#!/usr/bin/env bats
# Tests for bin/autopilot-init — interactive project setup command.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  UTILS_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Create a utils dir with essential system commands (symlinked).
  local cmd
  for cmd in bash cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id launchctl ps readlink; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Create mock commands for all prerequisites.
  _create_mock "claude"
  _create_mock "gh"
  _create_mock "jq"
  _create_mock "git"
  _create_mock "timeout"

  # Mock gh auth status to succeed.
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"repo create"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"

  # Mock git to simulate being in a repo with a remote.
  cat > "$MOCK_BIN/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --is-inside-work-tree"*) echo "true"; exit 0 ;;
  *"remote get-url origin"*) echo "https://github.com/test/repo.git"; exit 0 ;;
  *"init"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"

  # Set HOME to temp dir for account detection tests.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"

  cd "$TEST_DIR"
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

# Ensure autopilot-schedule mock exists in MOCK_BIN.
_ensure_schedule_mock() {
  local fake_schedule="$MOCK_BIN/autopilot-schedule"
  cat > "$fake_schedule" << 'MOCK'
#!/usr/bin/env bash
echo "  mock: autopilot-schedule called"
exit 0
MOCK
  chmod +x "$fake_schedule"
}

# Run autopilot-init with isolated PATH (MOCK_BIN + UTILS_BIN only).
_run_init() {
  _ensure_schedule_mock
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-init" < /dev/null
}

# --- Prerequisite checks ---

@test "init: fails when claude is missing" {
  rm -f "$MOCK_BIN/claude"
  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude not found"* ]]
}

@test "init: fails when gh is missing" {
  rm -f "$MOCK_BIN/gh"
  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh not found"* ]]
}

@test "init: fails when jq is missing" {
  rm -f "$MOCK_BIN/jq"
  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq not found"* ]]
}

@test "init: fails when timeout is missing with coreutils hint" {
  rm -f "$MOCK_BIN/timeout"
  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout not found"* ]]
  [[ "$output" == *"brew install coreutils"* ]]
}

# --- Git repo checks ---

@test "init: fails in non-interactive mode when not a git repo" {
  # Mock git to say not a repo.
  cat > "$MOCK_BIN/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --is-inside-work-tree"*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"

  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git init"* ]]
}

# --- gh auth checks ---

@test "init: fails when gh auth is not configured" {
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"

  _run_init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh auth login"* ]]
}

# --- Full successful run ---

@test "init: creates tasks.md with sample tasks" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/tasks.md" ]

  # Check sample task content.
  [[ "$(cat "$TEST_DIR/tasks.md")" == *"Task 1: Add README.md"* ]]
  [[ "$(cat "$TEST_DIR/tasks.md")" == *"Task 2: Add .gitignore"* ]]
  [[ "$(cat "$TEST_DIR/tasks.md")" == *"Previously Completed"* ]]
}

@test "init: creates autopilot.conf with dangerously-skip-permissions" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/autopilot.conf" ]
  [[ "$(cat "$TEST_DIR/autopilot.conf")" == *"--dangerously-skip-permissions"* ]]
}

@test "init: creates .gitignore with .autopilot/" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/.gitignore" ]
  grep -qF '.autopilot/' "$TEST_DIR/.gitignore"
}

@test "init: appends to existing .gitignore without duplicating" {
  echo "node_modules/" > "$TEST_DIR/.gitignore"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]

  # Should contain both entries.
  grep -qF 'node_modules/' "$TEST_DIR/.gitignore"
  grep -qF '.autopilot/' "$TEST_DIR/.gitignore"

  # Should have exactly one .autopilot/ entry.
  local count
  count=$(grep -cF '.autopilot/' "$TEST_DIR/.gitignore")
  [ "$count" -eq 1 ]
}

@test "init: creates .autopilot/PAUSE file" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/.autopilot/PAUSE" ]
}

@test "init: prints setup complete message" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setup complete"* ]]
  [[ "$output" == *"autopilot start"* ]]
}

# --- Idempotency ---

@test "init: re-run skips existing tasks.md" {
  echo "# My existing tasks" > "$TEST_DIR/tasks.md"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]

  # Should not overwrite existing content.
  [[ "$(cat "$TEST_DIR/tasks.md")" == "# My existing tasks" ]]
  [[ "$output" == *"SKIP"*"tasks.md"* ]]
}

@test "init: re-run skips existing autopilot.conf" {
  echo "AUTOPILOT_CLAUDE_FLAGS=\"--test\"" > "$TEST_DIR/autopilot.conf"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]

  # Should not overwrite existing content.
  [[ "$(cat "$TEST_DIR/autopilot.conf")" == *"--test"* ]]
  [[ "$output" == *"SKIP"*"autopilot.conf"* ]]
}

@test "init: re-run does not duplicate .autopilot/ in .gitignore" {
  echo '.autopilot/' > "$TEST_DIR/.gitignore"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]

  local count
  count=$(grep -cF '.autopilot/' "$TEST_DIR/.gitignore")
  [ "$count" -eq 1 ]
  [[ "$output" == *"SKIP"*".autopilot/"* ]]
}

@test "init: full re-run is idempotent" {
  # First run.
  _run_init
  [ "$status" -eq 0 ]

  # Capture file contents.
  local tasks_md_before config_before gitignore_before
  tasks_md_before="$(cat "$TEST_DIR/tasks.md")"
  config_before="$(cat "$TEST_DIR/autopilot.conf")"
  gitignore_before="$(cat "$TEST_DIR/.gitignore")"

  # Second run.
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]

  # All files should be identical.
  [[ "$(cat "$TEST_DIR/tasks.md")" == "$tasks_md_before" ]]
  [[ "$(cat "$TEST_DIR/autopilot.conf")" == "$config_before" ]]
  [[ "$(cat "$TEST_DIR/.gitignore")" == "$gitignore_before" ]]
}

# --- Account detection ---

@test "init: detects two-account setup" {
  mkdir -p "$HOME/.claude-account1"
  mkdir -p "$HOME/.claude-account2"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Two-account setup detected"* ]]
}

@test "init: reports single-account setup when no dirs exist" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"single-account"* ]]
}

# --- Help flag ---

@test "init: --help prints usage and exits 0" {
  run "$REPO_DIR/bin/autopilot-init" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"autopilot-init"* ]]
}

# --- Examples file ---

@test "examples: tasks.example.md has autopilot init comment" {
  grep -q "autopilot init" "$REPO_DIR/examples/tasks.example.md"
}
