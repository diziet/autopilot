# Shared setup/teardown for dispatcher test files.
# Provides: setup, teardown, _create_tasks_file, _mock_gh, _mock_claude,
# _mock_timeout, _set_state, _set_task, _get_status, _write_test_gate_result.
# Usage: load helpers/dispatcher_setup

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

  # Mock all external commands to prevent real invocations.
  _mock_gh
  _mock_claude
  _mock_timeout
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"
}

# --- Shared Helpers ---

# Create a tasks file with N tasks.
_create_tasks_file() {
  local count="${1:-3}"
  local f="${TEST_PROJECT_DIR}/tasks.md"
  local i
  for (( i=1; i<=count; i++ )); do
    printf '## Task %d: Test task %d\nDo thing %d.\n\n' "$i" "$i" "$i" >> "$f"
  done
}

# Mock gh CLI to return canned responses.
_mock_gh() {
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr diff"*) echo "+added line" ;;
  *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr merge"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"api"*"git/ref"*) echo '{"object":{"sha":"abc123"}}' | jq -r '.object.sha' ;;
  *"api"*"pulls"*"reviews"*) echo "" ;;
  *"api"*"pulls"*"comments"*) echo "" ;;
  *"api"*"issues"*"comments"*) echo "" ;;
  *"api"*) echo '[]' ;;
  *) echo "mock-gh: $*" >&2; exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Mock claude CLI to return valid JSON.
_mock_claude() {
  cat > "${TEST_MOCK_BIN}/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"TITLE: Test PR\nVERDICT: APPROVE","session_id":"sess-123"}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
}

# Mock timeout to just run the command directly.
_mock_timeout() {
  cat > "${TEST_MOCK_BIN}/timeout" << 'MOCK'
#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

# Set pipeline state for a test.
_set_state() {
  local status="$1"
  write_state "$TEST_PROJECT_DIR" "status" "$status"
}

# Set current task number.
_set_task() {
  local num="$1"
  write_state_num "$TEST_PROJECT_DIR" "current_task" "$num"
}

# Read pipeline status.
_get_status() {
  read_state "$TEST_PROJECT_DIR" "status"
}

# Write test gate result file with given exit code.
_write_test_gate_result() {
  local code="$1"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "$code" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
}
