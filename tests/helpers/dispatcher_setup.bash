# Shared setup/teardown for dispatcher test files.
# Provides: setup, teardown, _create_tasks_file, _mock_gh, _mock_claude,
# _mock_timeout, _mock_metrics, _mock_pending_pipeline,
# _set_state, _set_task, _get_status, _write_test_gate_result.
# Usage: load helpers/dispatcher_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
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
  echo "# Test" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Mock all external commands as shell functions (faster than script mocks).
  _mock_gh
  _mock_claude
  _mock_timeout
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

# Mock gh CLI as a shell function (no fork+exec overhead).
_mock_gh() {
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"--json state"*) echo "MERGED" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr merge"*) return 0 ;;
      *"pr ready"*) return 0 ;;
      *"pr comment"*) return 0 ;;
      *"api"*"git/ref"*) echo 'abc123' ;;
      *"api"*"pulls"*"reviews"*) echo "" ;;
      *"api"*"pulls"*"comments"*) echo "" ;;
      *"api"*"issues"*"comments"*) echo "" ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh
}

# Mock claude CLI as a shell function (no fork+exec overhead).
_mock_claude() {
  claude() {
    echo '{"result":"TITLE: Test PR\nVERDICT: APPROVE","session_id":"sess-123"}'
  }
  export -f claude
}

# Mock timeout as a shell function (no fork+exec overhead).
_mock_timeout() {
  timeout() { shift; "$@"; }
  export -f timeout
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

# Create a commit on the current branch for testing pipeline push/PR flow.
_create_test_commit() {
  local msg="${1:-feat: test commit}"
  echo "change-$(date +%s)" >> "$TEST_PROJECT_DIR/testfile.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "$msg" -q
}

# Mock metrics/summary functions used by merged and PR-verification tests.
_mock_metrics() {
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition
}

# Mock the full pending-handler pipeline (preflight, coder, push, PR creation).
# Override run_coder after calling this if custom coder behavior is needed.
_mock_pending_pipeline() {
  run_preflight() { return 0; }
  # Use $7 (work_dir) from run_coder's call signature, falling back to $1.
  run_coder() {
    local work_dir="${7:-$1}"
    echo "change" >> "$work_dir/testfile.txt"
    git -C "$work_dir" add -A >/dev/null 2>&1
    git -C "$work_dir" commit -m "feat: implement" -q
    return 0
  }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  create_draft_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  detect_task_pr() { return 1; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  mark_pr_ready() { return 0; }
  export -f run_preflight run_coder push_branch generate_pr_body
  export -f create_task_pr create_draft_pr detect_task_pr run_test_gate_background
  export -f _trigger_reviewer_background mark_pr_ready
}

# Override gh mock to return a specific PR state for state queries.
_mock_gh_pr_state() {
  export _MOCK_PR_STATE="$1"
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"--json state"*) echo "$_MOCK_PR_STATE" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr merge"*) return 0 ;;
      *"pr ready"*) return 0 ;;
      *"pr comment"*) return 0 ;;
      *"api"*"git/ref"*) echo 'abc123' ;;
      *"api"*"pulls"*"reviews"*) echo "" ;;
      *"api"*"pulls"*"comments"*) echo "" ;;
      *"api"*"issues"*"comments"*) echo "" ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh
}

# Override gh mock to make all gh commands fail (simulates network failure).
_mock_gh_failure() {
  gh() { return 1; }
  export -f gh
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
