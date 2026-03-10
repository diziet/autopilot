#!/usr/bin/env bats
# Tests for bin/autopilot-init — interactive project setup command.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup_file() {
  # Build template utils and mocks once per file.
  export _INIT_UTILS_TEMPLATE="${BATS_FILE_TMPDIR}/utils_template"
  export _INIT_MOCK_TEMPLATE="${BATS_FILE_TMPDIR}/mock_template"
  mkdir -p "$_INIT_UTILS_TEMPLATE" "$_INIT_MOCK_TEMPLATE"

  local cmd real_path
  for cmd in bash cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id launchctl ps wc seq; do
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    # Builtins return bare names (e.g. "echo"); fall back to which for path.
    if [[ "$real_path" != /* ]]; then
      real_path="$(which "$cmd" 2>/dev/null || true)"
    fi
    if [[ "$real_path" == /* ]]; then
      ln -sf "$real_path" "$_INIT_UTILS_TEMPLATE/$cmd"
    fi
  done

  # Default mocks.
  for cmd in claude jq timeout; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_INIT_MOCK_TEMPLATE/$cmd"
    chmod +x "$_INIT_MOCK_TEMPLATE/$cmd"
  done

  cat > "$_INIT_MOCK_TEMPLATE/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"repo create"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$_INIT_MOCK_TEMPLATE/gh"

  cat > "$_INIT_MOCK_TEMPLATE/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --is-inside-work-tree"*) echo "true"; exit 0 ;;
  *"remote get-url origin"*) echo "https://github.com/test/repo.git"; exit 0 ;;
  *"init"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$_INIT_MOCK_TEMPLATE/git"

  # Pre-create mock autopilot-schedule for reuse.
  cat > "$_INIT_MOCK_TEMPLATE/autopilot-schedule" << 'MOCK'
#!/usr/bin/env bash
echo "  mock: autopilot-schedule called"
exit 0
MOCK
  chmod +x "$_INIT_MOCK_TEMPLATE/autopilot-schedule"

  # Run init once in a clean dir and cache output + artifacts for assertion tests.
  export _INIT_CACHED_DIR="${BATS_FILE_TMPDIR}/cached_init"
  mkdir -p "$_INIT_CACHED_DIR"
  local mock_bin="${BATS_FILE_TMPDIR}/cached_mock_bin"
  mkdir -p "$mock_bin"
  cp "$_INIT_MOCK_TEMPLATE"/* "$mock_bin/"
  export _INIT_CACHED_HOME="${BATS_FILE_TMPDIR}/cached_home"
  mkdir -p "$_INIT_CACHED_HOME"
  export _INIT_CACHED_OUTPUT
  _INIT_CACHED_OUTPUT="$(cd "$_INIT_CACHED_DIR" && HOME="$_INIT_CACHED_HOME" PATH="$mock_bin:$_INIT_UTILS_TEMPLATE" "$REPO_DIR/bin/autopilot-init" < /dev/null 2>&1)"
  export _INIT_CACHED_STATUS=$?
}

teardown_file() {
  rm -rf "${BATS_FILE_TMPDIR}/utils_template" "${BATS_FILE_TMPDIR}/mock_template" \
         "${BATS_FILE_TMPDIR}/cached_init" "${BATS_FILE_TMPDIR}/cached_mock_bin" \
         "${BATS_FILE_TMPDIR}/cached_home"
}

setup() {
  TEST_DIR="$BATS_TEST_TMPDIR/test_dir"
  MOCK_BIN="$BATS_TEST_TMPDIR/mock_bin"
  # Use shared utils template directly (read-only, never modified per test).
  UTILS_BIN="$_INIT_UTILS_TEMPLATE"
  mkdir -p "$TEST_DIR" "$MOCK_BIN"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Copy only mocks (small, may be modified per test).
  cp "$_INIT_MOCK_TEMPLATE"/* "$MOCK_BIN/"

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
  # Already copied from template — no-op unless explicitly removed.
  :
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

# --- Full successful run (use cached output) ---

@test "init: creates tasks.md with sample tasks" {
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [ -f "$_INIT_CACHED_DIR/tasks.md" ]

  # Check sample task content.
  [[ "$(cat "$_INIT_CACHED_DIR/tasks.md")" == *"Task 1: Add README.md"* ]]
  [[ "$(cat "$_INIT_CACHED_DIR/tasks.md")" == *"Task 2: Add .gitignore"* ]]
  [[ "$(cat "$_INIT_CACHED_DIR/tasks.md")" == *"Previously Completed"* ]]
}

@test "init: creates autopilot.conf with dangerously-skip-permissions" {
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [ -f "$_INIT_CACHED_DIR/autopilot.conf" ]
  [[ "$(cat "$_INIT_CACHED_DIR/autopilot.conf")" == *"--dangerously-skip-permissions"* ]]
}

@test "init: creates .gitignore with .autopilot/" {
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [ -f "$_INIT_CACHED_DIR/.gitignore" ]
  grep -qF '.autopilot/' "$_INIT_CACHED_DIR/.gitignore"
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
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [ -f "$_INIT_CACHED_DIR/.autopilot/PAUSE" ]
}

@test "init: prints setup complete message" {
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [[ "$_INIT_CACHED_OUTPUT" == *"Setup complete"* ]]
  [[ "$_INIT_CACHED_OUTPUT" == *"autopilot start"* ]]
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
  # Use cached dir — run init in it again (second run).
  # We need a fresh copy since cached dir is shared.
  local rerun_dir="$TEST_DIR/rerun"
  cp -r "$_INIT_CACHED_DIR" "$rerun_dir"
  cd "$rerun_dir"

  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-init" < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]

  # All files should be identical to cached.
  [[ "$(cat "$rerun_dir/tasks.md")" == "$(cat "$_INIT_CACHED_DIR/tasks.md")" ]]
  [[ "$(cat "$rerun_dir/autopilot.conf")" == "$(cat "$_INIT_CACHED_DIR/autopilot.conf")" ]]
  [[ "$(cat "$rerun_dir/.gitignore")" == "$(cat "$_INIT_CACHED_DIR/.gitignore")" ]]

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
  [ "$_INIT_CACHED_STATUS" -eq 0 ]
  [ -f "$_INIT_CACHED_DIR/CLAUDE.md" ]
  [[ "$_INIT_CACHED_OUTPUT" == *"Generated CLAUDE.md"* ]]
  [[ "$_INIT_CACHED_OUTPUT" == *"Project Details"* ]]
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
