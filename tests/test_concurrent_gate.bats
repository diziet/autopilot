#!/usr/bin/env bats
# Tests for concurrent background test gate and immediate reviewer trigger.
# Verifies: background test gate runs concurrently with reviewer,
# test gate failure after review still triggers test_fixing,
# test gate pass with clean reviews skips fixer, and reviewer
# triggered immediately on pr_open (not waiting for cron).

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source the dispatcher module (sources all deps).
  source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state for tests.
  init_pipeline "$TEST_PROJECT_DIR"

  # Create a minimal tasks file.
  _create_tasks_file 3

  # Create CLAUDE.md for preflight.
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Set up a fake git repo.
  git -C "$TEST_PROJECT_DIR" init -q -b main
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"
  echo "initial" > "$TEST_PROJECT_DIR/README.md"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "init" -q
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  # Put mock bin first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"

  # Mock all external commands.
  _mock_gh
  _mock_claude
  _mock_timeout
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"
}

# --- Test Helpers ---

# Create a tasks file with N tasks.
_create_tasks_file() {
  local count="${1:-3}"
  local f="${TEST_PROJECT_DIR}/tasks.md"
  local i
  for (( i=1; i<=count; i++ )); do
    printf '## Task %d: Test task %d\nDo thing %d.\n\n' "$i" "$i" "$i" >> "$f"
  done
}

# Mock gh CLI.
_mock_gh() {
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"api"*) echo '[]' ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Mock claude CLI.
_mock_claude() {
  cat > "${TEST_MOCK_BIN}/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"TITLE: Test PR\nVERDICT: APPROVE","session_id":"s-1"}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
}

# Mock timeout.
_mock_timeout() {
  cat > "${TEST_MOCK_BIN}/timeout" << 'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

# Set pipeline state.
_set_state() { write_state "$TEST_PROJECT_DIR" "status" "$1"; }

# Set current task number.
_set_task() { write_state_num "$TEST_PROJECT_DIR" "current_task" "$1"; }

# Read pipeline status.
_get_status() { read_state "$TEST_PROJECT_DIR" "status"; }

# Write test gate result file with given exit code.
_write_test_gate_result() {
  local code="$1"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "$code" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
}

# --- Background Test Gate Concurrency Tests ---

@test "coder result: background test gate runs concurrently — always pr_open" {
  _set_state "implementing"
  _set_task 1

  # Track that background test gate was called (not synchronous).
  local bg_called=0
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() {
    echo "bg_test_gate_called" > "$TEST_PROJECT_DIR/.autopilot/bg_called"
    echo "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Always transitions to pr_open (background test gate is async).
  [ "$(_get_status)" = "pr_open" ]

  # Verify background test gate was invoked.
  [ -f "$TEST_PROJECT_DIR/.autopilot/bg_called" ]
}

@test "coder result: reviewer triggered immediately on pr_open" {
  _set_state "implementing"
  _set_task 1

  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() {
    echo "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  }
  # Track that reviewer was triggered.
  _trigger_reviewer_background() {
    echo "reviewer_triggered" > "$TEST_PROJECT_DIR/.autopilot/reviewer_flag"
  }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Reviewer should be triggered immediately.
  [ -f "$TEST_PROJECT_DIR/.autopilot/reviewer_flag" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/reviewer_flag")" = "reviewer_triggered" ]
}

@test "coder result: test_gate_result_file stored in state" {
  _set_state "implementing"
  _set_task 1

  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/my_result_file"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Result file path should be stored in state.
  local stored
  stored="$(read_state "$TEST_PROJECT_DIR" "test_gate_result_file")"
  [ "$stored" = "/tmp/my_result_file" ]
}

# --- pr_open: Background Test Gate Result Handling ---

@test "pr_open: no result file stays in pr_open (test still running)" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # No result file — test gate still running.
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate pass stays in pr_open for review" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate skip stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_SKIP"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate already verified stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_ALREADY_VERIFIED"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "pr_open: test gate failure transitions to test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]
}

@test "pr_open: test gate failure after review still triggers test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Simulate: reviewer already posted results (reviewed.json exists).
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"abc","is_clean":false}}}
JSON

  # But background test gate failed.
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"

  # Test gate failure takes precedence — go fix tests first.
  [ "$(_get_status)" = "test_fixing" ]
}

# --- Independent Failure Handling ---

@test "test gate pass with clean reviews leads to fixed (skips fixer)" {
  # Step 1: Start in pr_open with passing test gate.
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  _handle_pr_open "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]

  # Step 2: Reviewer marks as reviewed with clean reviews.
  update_status "$TEST_PROJECT_DIR" "reviewed"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":true}}}
JSON

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "test gate fail returns to test_fixing even if reviews clean" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Clean reviews exist.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true}}}
JSON

  # But test gate failed.
  _write_test_gate_result "$TESTGATE_FAIL"

  _handle_pr_open "$TEST_PROJECT_DIR"
  # Test failure caught in pr_open, transitions to test_fixing.
  [ "$(_get_status)" = "test_fixing" ]
}

@test "pr_open to test_fixing is a valid state transition" {
  _set_state "pr_open"

  # Verify pr_open:test_fixing is in valid transitions.
  _is_valid_transition "pr_open" "test_fixing"
}

# --- Reviewer Trigger Tests ---

@test "reviewer trigger: called during coder result after pr_open transition" {
  _set_state "implementing"
  _set_task 1

  local trigger_order=""
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() {
    echo "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  }
  # Record ordering: reviewer trigger must happen after pr_open.
  _trigger_reviewer_background() {
    local status
    status="$(read_state "$TEST_PROJECT_DIR" "status")"
    echo "$status" > "$TEST_PROJECT_DIR/.autopilot/trigger_state"
  }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0

  # Reviewer trigger should see pr_open state (called after transition).
  [ -f "$TEST_PROJECT_DIR/.autopilot/trigger_state" ]
  [ "$(cat "$TEST_PROJECT_DIR/.autopilot/trigger_state")" = "pr_open" ]
}

# --- Dispatch tick integration with pr_open ---

@test "dispatch_tick: pr_open with failed test gate goes to test_fixing" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_FAIL"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "test_fixing" ]
}

@test "dispatch_tick: pr_open with passing test gate stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  _write_test_gate_result "$TESTGATE_PASS"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "dispatch_tick: pr_open with no result stays in pr_open" {
  _set_state "pr_open"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}
