# Shared setup/teardown for dispatcher test files.
# Provides: setup, teardown, _create_tasks_file, _mock_gh, _mock_claude,
# _mock_timeout, _set_state, _set_task, _get_status, _write_test_gate_result.
# Usage: load helpers/dispatcher_setup

load helpers/test_template

# Source libs once at file level (not per-test).
source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  load_config "$TEST_PROJECT_DIR"

  # Use direct-checkout mode for existing dispatcher tests.
  AUTOPILOT_USE_WORKTREES="false"

  # Initialize pipeline state for tests.
  init_pipeline "$TEST_PROJECT_DIR"

  # Create a minimal tasks file.
  _create_tasks_file 3

  # Create CLAUDE.md for preflight.
  printf '%s\n' "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Template already has gh, claude, timeout mocks.
  # Override claude mock with dispatcher-specific response.
  _write_mock "${TEST_MOCK_BIN}/claude" '#!/usr/bin/env bash
echo '"'"'{"result":"TITLE: Test PR\nVERDICT: APPROVE","session_id":"sess-123"}'"'"''
}

teardown() {
  : # BATS_TEST_TMPDIR is auto-cleaned
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
  _write_mock "${TEST_MOCK_BIN}/gh" '#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*"--json state"*) echo "MERGED" ;;
  *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr diff"*) echo "+added line" ;;
  *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr merge"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"api"*"git/ref"*) echo '"'"'{"object":{"sha":"abc123"}}'"'"' | jq -r ".object.sha" ;;
  *"api"*"pulls"*"reviews"*) echo "" ;;
  *"api"*"pulls"*"comments"*) echo "" ;;
  *"api"*"issues"*"comments"*) echo "" ;;
  *"api"*) echo "[]" ;;
  *) echo "mock-gh: $*" >&2; exit 0 ;;
esac'
}

# Mock claude CLI to return valid JSON.
_mock_claude() {
  _write_mock "${TEST_MOCK_BIN}/claude" '#!/usr/bin/env bash
echo '"'"'{"result":"TITLE: Test PR\nVERDICT: APPROVE","session_id":"sess-123"}'"'"''
}

# Mock timeout to just run the command directly.
_mock_timeout() {
  _write_mock "${TEST_MOCK_BIN}/timeout" '#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"'
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
  printf '%s\n' "$code" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
}

# Create a commit on the current branch for testing pipeline push/PR flow.
_create_test_commit() {
  local msg="${1:-feat: test commit}"
  printf 'change-%s\n' "$$-$RANDOM" >> "$TEST_PROJECT_DIR/testfile.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "$msg" -q
}

# Override gh mock to return a specific PR state for state queries.
_mock_gh_pr_state() {
  local pr_state="$1"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*"--json state"*) echo "${pr_state}" ;;
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
  *) echo "mock-gh: \$*" >&2; exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Override gh mock to make all gh commands fail (simulates network failure).
_mock_gh_failure() {
  _write_mock "${TEST_MOCK_BIN}/gh" '#!/usr/bin/env bash
exit 1'
}

# Switch to a task branch and create a commit (simulates coder output).
_setup_coder_commits() {
  local task_number="${1:-1}"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  git -C "$TEST_PROJECT_DIR" checkout -b "$branch_name" -q 2>/dev/null || \
    git -C "$TEST_PROJECT_DIR" checkout "$branch_name" -q 2>/dev/null
  _create_test_commit "feat: implement task ${task_number}"
}
