# Shared setup/teardown for review_entry test files.
# Provides: setup_file, teardown_file, setup, teardown, mock helpers.
# Usage: load helpers/review_entry_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/review-runner.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  GH_MOCK_DIR="$BATS_TEST_TMPDIR/gh_mocks"
  mkdir -p "$GH_MOCK_DIR"
  export GH_MOCK_DIR

  # Source the review runner module (sources all deps).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state for tests.
  init_pipeline "$TEST_PROJECT_DIR"

  # Mock all external commands (override template mocks with gh logging variant).
  _mock_gh
  _mock_claude
  _mock_timeout
}

teardown() {
  : # BATS_TEST_TMPDIR auto-cleans
}

# --- Shared Helpers ---

# Mock gh CLI as shell function (logs calls, returns canned responses).
_mock_gh() {
  gh() {
    echo "gh $*" >> "${GH_MOCK_DIR}/gh-calls.log"
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"headRefOid"*) echo "abc123def456" ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr comment"*) return 0 ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh
}

# Mock claude CLI as shell function.
_mock_claude() {
  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
}

# Mock timeout as shell function (skips timeout value, runs command directly).
_mock_timeout() {
  timeout() { shift; "$@"; }
  export -f timeout
}

# Set pipeline state for a test.
_set_state() {
  local status="$1"
  write_state "$TEST_PROJECT_DIR" "status" "$status"
}

# Read pipeline status.
_get_status() {
  read_state "$TEST_PROJECT_DIR" "status"
}
