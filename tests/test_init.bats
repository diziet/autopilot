#!/usr/bin/env bats
# Tests for bin/autopilot-init — interactive project setup command.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_DIR="$BATS_TEST_TMPDIR/test_dir"
  MOCK_BIN="$BATS_TEST_TMPDIR/mock_bin"
  UTILS_BIN="$BATS_TEST_TMPDIR/utils_bin"
  mkdir -p "$TEST_DIR" "$MOCK_BIN" "$UTILS_BIN"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Create a utils dir with essential system commands (symlinked).
  local cmd
  for cmd in bash cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id launchctl ps wc seq; do
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

# Write N lines to a file.
_create_lines() {
  local file="$1"
  local count="$2"
  local i
  for i in $(seq 1 "$count"); do
    echo "Line $i" >> "$file"
  done
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

@test "init: re-run skips existing PAUSE file" {
  mkdir -p "$TEST_DIR/.autopilot"
  touch "$TEST_DIR/.autopilot/PAUSE"
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"*".autopilot/PAUSE"* ]]
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

  # Summary should show all files as skipped, not created.
  [[ "$output" == *"SKIP"*"tasks.md"* ]]
  [[ "$output" == *"SKIP"*"autopilot.conf"* ]]
  [[ "$output" == *"SKIP"*".autopilot/"* ]]
  [[ "$output" == *"SKIP"*".autopilot/PAUSE"* ]]
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

# --- CLAUDE.md scaffolding ---

@test "init: creates CLAUDE.md when none exists and no global" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/CLAUDE.md" ]
  [[ "$output" == *"Generated CLAUDE.md"* ]]
  [[ "$output" == *"Project Details"* ]]
}

@test "init: skips CLAUDE.md when project CLAUDE.md has >10 lines" {
  _create_lines "$TEST_DIR/CLAUDE.md" 15

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Existing CLAUDE.md found"* ]]

  # Content should be unchanged.
  local line_count
  line_count=$(wc -l < "$TEST_DIR/CLAUDE.md" | tr -d ' ')
  [ "$line_count" -eq 15 ]
}

@test "init: skips CLAUDE.md when global CLAUDE.md has >10 lines" {
  mkdir -p "$HOME/.claude"
  _create_lines "$HOME/.claude/CLAUDE.md" 15

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Global CLAUDE.md found"* ]]

  # No project CLAUDE.md should be created.
  [ ! -f "$TEST_DIR/CLAUDE.md" ]
}

@test "init: CLAUDE.md template contains placeholder section" {
  [ -f "$REPO_DIR/examples/CLAUDE.example.md" ]
  grep -q "# Project Details" "$REPO_DIR/examples/CLAUDE.example.md"
  grep -q "Language:" "$REPO_DIR/examples/CLAUDE.example.md"
  grep -q "Test command:" "$REPO_DIR/examples/CLAUDE.example.md"
  grep -q "Lint command:" "$REPO_DIR/examples/CLAUDE.example.md"
}

@test "init: replaces short CLAUDE.md with template" {
  # Create a short CLAUDE.md (under the threshold).
  echo "# My Project" > "$TEST_DIR/CLAUDE.md"

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Replaced short CLAUDE.md"* ]]

  # Should be overwritten with the template.
  grep -q "Project Details" "$TEST_DIR/CLAUDE.md"
}

# --- Examples file ---

@test "examples: tasks.example.md has autopilot init comment" {
  grep -q "autopilot init" "$REPO_DIR/examples/tasks.example.md"
}
