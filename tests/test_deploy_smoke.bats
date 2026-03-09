#!/usr/bin/env bats
# Deploy smoke tests — validates the full "deploy autopilot to a new project"
# flow by exercising plist generation, preflight, reviewer skip, and argument
# rejection end-to-end against a temp git repo with mock binaries.
# Uses the mock harness from tests/fixtures/bin/ (Task 41).

REPO_DIR="$BATS_TEST_DIRNAME/.."

load helpers/test_template

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_OUTPUT_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # --- Create a minimal project in the temp dir ---

  # Initialize git repo.
  git -C "$TEST_PROJECT_DIR" init -q -b main
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"

  # Minimal tasks.md with one trivial task.
  cat > "$TEST_PROJECT_DIR/tasks.md" <<'TASKS'
# Tasks

## Task 1: Add a hello world script

Create `hello.sh` that prints "Hello, world!".
TASKS

  # Minimal CLAUDE.md.
  cat > "$TEST_PROJECT_DIR/CLAUDE.md" <<'CLAUDE'
# Test Project

Run `make test` to test.
CLAUDE

  # autopilot.conf with required flags.
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_FLAGS=--dangerously-skip-permissions
CONF

  # Initial commit.
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -q -m "init"
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/test/repo.git" 2>/dev/null || true

  # Initialize .autopilot/ state.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Create mock launchctl to avoid real launchd interaction.
  cat > "$MOCK_BIN/launchctl" <<'MOCK'
#!/bin/bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/launchctl"

  # Create mock id for consistent uid.
  cat > "$MOCK_BIN/id" <<'MOCK'
#!/bin/bash
if [[ "$1" == "-u" ]]; then echo "501"; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/id"

  # Save original PATH and HOME for restoration.
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"
}

teardown() {
  PATH="$OLD_PATH"
  HOME="$OLD_HOME"
  rm -rf "$TEST_PROJECT_DIR" "$TEST_OUTPUT_DIR" "$MOCK_BIN"
}

# --- Test Helpers ---

# Create mock gh (with auth support), claude, and timeout in MOCK_BIN and update PATH.
_setup_mock_binaries() {
  cat > "$MOCK_BIN/gh" <<'MOCK'
#!/bin/bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
echo "mock-gh: $*" >&2
exit 0
MOCK
  chmod +x "$MOCK_BIN/gh"

  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/bin/bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/claude"

  cat > "$MOCK_BIN/timeout" <<'MOCK'
#!/bin/bash
shift; exec "$@"
MOCK
  chmod +x "$MOCK_BIN/timeout"

  export PATH="$MOCK_BIN:$OLD_PATH"
}

# ============================================================
# Plist generation tests
# ============================================================

@test "deploy: plist generation succeeds against temp project" {
  PATH="$MOCK_BIN:$OLD_PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot-dispatch"* ]]
  [[ "$output" == *"autopilot-review"* ]]
}

@test "deploy: dispatcher plist PATH includes ~/.local/bin" {
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/.local/bin"

  # Create a mock claude in ~/.local/bin so it gets included.
  cat > "$TEST_OUTPUT_DIR/.local/bin/claude" <<'MOCK'
#!/bin/bash
echo "mock"
MOCK
  chmod +x "$TEST_OUTPUT_DIR/.local/bin/claude"

  PATH="$TEST_OUTPUT_DIR/.local/bin:$MOCK_BIN:$OLD_PATH"
  unset AUTOPILOT_CLAUDE_CMD

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Extract dispatcher plist (before --- separator).
  local dispatcher_plist
  dispatcher_plist="$(echo "$output" | sed '/^---$/,$d')"

  # PATH in the plist should include ~/.local/bin.
  echo "$dispatcher_plist" | grep -q "$TEST_OUTPUT_DIR/.local/bin"
}

@test "deploy: reviewer plist does NOT pass extra positional args" {
  PATH="$MOCK_BIN:$OLD_PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Extract reviewer plist (after --- separator).
  local reviewer_plist
  reviewer_plist="$(echo "$output" | sed -n '/^---$/,$p' | tail -n +2)"

  # ProgramArguments should have exactly 2 entries: the command and the project dir.
  # There must NOT be a third <string> element (no account number as arg 2).
  local arg_count
  arg_count="$(echo "$reviewer_plist" \
    | sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' \
    | grep -c '<string>')"
  [ "$arg_count" -eq 2 ]
}

@test "deploy: both plists have CLAUDE_CONFIG_DIR when account dir exists" {
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/.claude-account1"
  PATH="$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Extract dispatcher plist.
  local dispatcher_plist
  dispatcher_plist="$(echo "$output" | sed '/^---$/,$d')"

  # Extract reviewer plist.
  local reviewer_plist
  reviewer_plist="$(echo "$output" | sed -n '/^---$/,$p' | tail -n +2)"

  # Both should contain CLAUDE_CONFIG_DIR.
  echo "$dispatcher_plist" | grep -q 'CLAUDE_CONFIG_DIR'
  echo "$reviewer_plist" | grep -q 'CLAUDE_CONFIG_DIR'

  # Both should reference the account dir.
  echo "$dispatcher_plist" | grep -q '.claude-account1'
  echo "$reviewer_plist" | grep -q '.claude-account1'
}

@test "deploy: CLAUDE_CONFIG_DIR absent when account dir missing" {
  export HOME="$TEST_OUTPUT_DIR"
  # No .claude-account77 directory exists.
  PATH="$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 77 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  [[ "$output" != *"CLAUDE_CONFIG_DIR"* ]]
}

@test "deploy: WorkingDirectory points to the project" {
  PATH="$MOCK_BIN:$OLD_PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Both plists should have the project dir as WorkingDirectory.
  local wd_count
  wd_count="$(echo "$output" | grep -A1 '<key>WorkingDirectory</key>' \
    | grep -c "$TEST_PROJECT_DIR")"
  [ "$wd_count" -eq 2 ]
}

# ============================================================
# Preflight tests
# ============================================================

@test "deploy: preflight passes with mock gh and claude on PATH" {
  source "$REPO_DIR/lib/preflight.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  _setup_mock_binaries

  # Run preflight — should pass with all conditions met.
  run_preflight "$TEST_PROJECT_DIR"
}

# ============================================================
# Reviewer skip tests
# ============================================================

@test "deploy: reviewer skips cleanly when state is pending" {
  # Source review-runner (sources deps).
  source "$REPO_DIR/lib/review-runner.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # State is pending by default after init.
  local status_val
  status_val="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status_val" = "pending" ]

  # Run the cron review logic — should skip with REVIEW_SKIP.
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "deploy: reviewer logs 'not pr_open — skipping' for pending state" {
  source "$REPO_DIR/lib/review-runner.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Run cron review in pending state.
  _run_cron_review "$TEST_PROJECT_DIR" || true

  # Verify the skip message was logged.
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  [ -f "$log_file" ]
  grep -q "not pr_open" "$log_file"
}

@test "deploy: reviewer entry point exits cleanly for non-pr_open state" {
  _setup_mock_binaries

  source "$REPO_DIR/lib/state.sh"
  init_pipeline "$TEST_PROJECT_DIR"
  # State is pending after init.

  # Run the actual entry point.
  run "$REPO_DIR/bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# ============================================================
# Argument rejection tests
# ============================================================

@test "deploy: autopilot-review rejects extra positional arg" {
  _setup_mock_binaries

  source "$REPO_DIR/lib/state.sh"
  init_pipeline "$TEST_PROJECT_DIR"

  # Extra positional arg (e.g., account number from old launchd plist) is rejected.
  run "$REPO_DIR/bin/autopilot-review" "$TEST_PROJECT_DIR" "2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}
