#!/usr/bin/env bats
# Tests for bin/autopilot-review and lib/review-runner.sh — quick guards,
# cron mode, standalone mode, review cycle orchestration, and state transitions.
# All external commands (claude, gh, git ops) are mocked.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"
  GH_MOCK_DIR="$(mktemp -d)"
  export GH_MOCK_DIR

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source the review runner module (sources all deps).
  source "$BATS_TEST_DIRNAME/../lib/review-runner.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state for tests.
  init_pipeline "$TEST_PROJECT_DIR"

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
  rm -rf "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN" "$GH_MOCK_DIR"
}

# --- Test Helpers ---

# Mock gh CLI to return canned responses and log all calls.
_mock_gh() {
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
# Log every call for assertion.
echo "gh $*" >> "${GH_MOCK_DIR}/gh-calls.log"
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*"headRefOid"*) echo "abc123def456" ;;
  *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
  *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr diff"*) echo "+added line" ;;
  *"pr comment"*) exit 0 ;;
  *"api"*) echo '[]' ;;
  *) echo "mock-gh: $*" >&2; exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Mock claude CLI to return valid JSON with NO_ISSUES_FOUND.
_mock_claude() {
  cat > "${TEST_MOCK_BIN}/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
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

# Read pipeline status.
_get_status() {
  read_state "$TEST_PROJECT_DIR" "status"
}

# --- Quick Guards (bin/autopilot-review) ---

@test "quick guard: PAUSE file causes immediate exit" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # State should be unchanged — no work was done.
  [ "$(_get_status)" = "pending" ]
}

@test "quick guard: exits when review lock held by live PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # State should be unchanged.
  [ "$(_get_status)" = "pending" ]
}

@test "quick guard: proceeds when review lock held by dead PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999" > "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  # Script should proceed past guard (dead PID) and run cron review.
  # State is pending, so cron review will skip — exits cleanly.
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "quick guard: no lock file allows entry" {
  rm -f "${TEST_PROJECT_DIR}/.autopilot/locks/review.lock"
  # Script should proceed, run cron review, skip (state is pending).
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- Cron Mode (_run_cron_review) ---

@test "cron: skips when state is pending" {
  _set_state "pending"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is implementing" {
  _set_state "implementing"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is completed" {
  _set_state "completed"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is reviewed" {
  _set_state "reviewed"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is fixing" {
  _set_state "fixing"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: skips when state is merging" {
  _set_state "merging"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_SKIP" ]
}

@test "cron: errors when pr_open but no pr_number" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" ""
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "cron: errors when pr_open with pr_number 0" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "0"
  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "cron: runs review cycle when pr_open with valid PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Use a single-reviewer config for speed.
  AUTOPILOT_REVIEWERS="general"

  _run_cron_review "$TEST_PROJECT_DIR"
  # After review, state should transition to reviewed.
  [ "$(_get_status)" = "reviewed" ]
}

@test "cron: transitions to reviewed after successful review" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _run_cron_review "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
}

@test "cron: stays in pr_open when diff fetch fails" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "999"

  # Mock gh to fail on diff.
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*"headRefOid"*) echo "abc123def" ;;
  *"pr view"*"headRefName"*) exit 1 ;;
  *"pr diff"*) exit 1 ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]
  # State should remain pr_open for retry.
  [ "$(_get_status)" = "pr_open" ]
}

# --- Standalone Mode (_run_standalone_review) ---

@test "standalone: rejects non-numeric PR number" {
  run _run_standalone_review "$TEST_PROJECT_DIR" "abc"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: rejects empty PR number" {
  run _run_standalone_review "$TEST_PROJECT_DIR" ""
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: rejects PR number with mixed content" {
  run _run_standalone_review "$TEST_PROJECT_DIR" "42abc"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "standalone: runs review for valid PR number" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  _run_standalone_review "$TEST_PROJECT_DIR" "42"
  # Standalone mode should NOT change pipeline state.
  [ "$(_get_status)" = "pr_open" ]
}

@test "standalone: does not modify pipeline state" {
  _set_state "pending"
  AUTOPILOT_REVIEWERS="general"

  _run_standalone_review "$TEST_PROJECT_DIR" "42"
  # State should remain pending — standalone never touches state.
  [ "$(_get_status)" = "pending" ]
}

@test "standalone: works even when state is not pr_open" {
  _set_state "implementing"
  AUTOPILOT_REVIEWERS="general"

  run _run_standalone_review "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq "$REVIEW_OK" ]
  # State stays implementing — standalone mode is state-agnostic.
  [ "$(_get_status)" = "implementing" ]
}

# --- Review Cycle (_execute_review_cycle) ---

@test "review cycle: fetches diff and runs reviewers" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_OK" ]
}

@test "review cycle: handles diff too large (exit 2)" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Override fetch_pr_diff to return exit 2 (diff too large).
  fetch_pr_diff() { return 2; }
  export -f fetch_pr_diff

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "review cycle: handles diff fetch failure (exit 1)" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  fetch_pr_diff() { return 1; }
  export -f fetch_pr_diff

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

@test "review cycle: uses placeholder when head SHA unavailable" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  # Mock gh to fail on headRefOid but succeed on diff.
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"headRefOid"*) exit 1 ;;
  *"headRefName"*) echo "autopilot/task-1" ;;
  *"pr diff"*) echo "+test change" ;;
  *"pr comment"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$status" -eq "$REVIEW_OK" ]
}

@test "review cycle: cron mode transitions pr_open to reviewed" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$(_get_status)" = "reviewed" ]
}

@test "review cycle: standalone mode does not transition state" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

# --- State Transition Helpers ---

@test "transition: _transition_after_review in cron mode updates state" {
  _set_state "pr_open"
  _transition_after_review "$TEST_PROJECT_DIR" "cron"
  [ "$(_get_status)" = "reviewed" ]
}

@test "transition: _transition_after_review in standalone mode is no-op" {
  _set_state "pr_open"
  _transition_after_review "$TEST_PROJECT_DIR" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

@test "transition: _transition_on_error stays in pr_open for cron" {
  _set_state "pr_open"
  _transition_on_error "$TEST_PROJECT_DIR" "cron"
  [ "$(_get_status)" = "pr_open" ]
}

@test "transition: _transition_on_error is no-op for standalone" {
  _set_state "pr_open"
  _transition_on_error "$TEST_PROJECT_DIR" "standalone"
  [ "$(_get_status)" = "pr_open" ]
}

# --- PR SHA Helper ---

@test "get_pr_head_sha: returns SHA from gh API" {
  local sha
  sha="$(_get_pr_head_sha "$TEST_PROJECT_DIR" "42")"
  [ "$sha" = "abc123def456" ]
}

@test "get_pr_head_sha: returns empty on gh failure" {
  cat > "${TEST_MOCK_BIN}/gh" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  local sha
  sha="$(_get_pr_head_sha "$TEST_PROJECT_DIR" "42" 2>/dev/null)" || true
  [ -z "$sha" ]
}

# --- Cleanup Helpers ---

@test "cleanup: _cleanup_diff_file removes existing file" {
  local tmp_file
  tmp_file="$(mktemp)"
  echo "test" > "$tmp_file"
  _cleanup_diff_file "$tmp_file"
  [ ! -f "$tmp_file" ]
}

@test "cleanup: _cleanup_diff_file handles empty path gracefully" {
  _cleanup_diff_file ""
  # Should not error.
}

@test "cleanup: _cleanup_diff_file handles nonexistent file" {
  _cleanup_diff_file "/nonexistent/path/file.txt"
  # Should not error.
}

@test "cleanup: _cleanup_result_dir removes existing directory" {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  echo "test" > "${tmp_dir}/file.txt"
  _cleanup_result_dir "$tmp_dir"
  [ ! -d "$tmp_dir" ]
}

@test "cleanup: _cleanup_result_dir handles empty path gracefully" {
  _cleanup_result_dir ""
  # Should not error.
}

# --- Lock Integration ---

@test "lock: review lock uses separate name from pipeline lock" {
  # Acquire review lock.
  acquire_lock "$TEST_PROJECT_DIR" "review"
  # Pipeline lock should still be acquirable.
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  release_lock "$TEST_PROJECT_DIR" "review"
  release_lock "$TEST_PROJECT_DIR" "pipeline"
}

@test "lock: review lock prevents concurrent review" {
  acquire_lock "$TEST_PROJECT_DIR" "review"
  # Second acquire should fail.
  run acquire_lock "$TEST_PROJECT_DIR" "review"
  [ "$status" -ne 0 ]
  release_lock "$TEST_PROJECT_DIR" "review"
}

# --- Exit Code Constants ---

@test "exit codes: REVIEW_OK is 0" {
  [ "$REVIEW_OK" -eq 0 ]
}

@test "exit codes: REVIEW_SKIP is 1" {
  [ "$REVIEW_SKIP" -eq 1 ]
}

@test "exit codes: REVIEW_ERROR is 2" {
  [ "$REVIEW_ERROR" -eq 2 ]
}

# --- Multi-Reviewer Integration ---

@test "multi-reviewer: all clean reviews sets _ALL_REVIEWS_CLEAN" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general,dry"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$(_get_status)" = "reviewed" ]
  [ "$_ALL_REVIEWS_CLEAN" = "true" ]
}

@test "multi-reviewer: works with single reviewer" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  run _execute_review_cycle "$TEST_PROJECT_DIR" "42" "cron"
  [ "$status" -eq "$REVIEW_OK" ]
}

# --- Entry Point Integration ---

@test "entry point: autopilot-review script is executable" {
  [ -x "$BATS_TEST_DIRNAME/../bin/autopilot-review" ]
}

@test "entry point: autopilot-review has correct shebang" {
  local first_line
  first_line="$(head -1 "$BATS_TEST_DIRNAME/../bin/autopilot-review")"
  [ "$first_line" = "#!/usr/bin/env bash" ]
}

@test "entry point: autopilot-review passes bash -n syntax check" {
  run bash -n "$BATS_TEST_DIRNAME/../bin/autopilot-review"
  [ "$status" -eq 0 ]
}

# --- Argument Handling (flag-based PR number) ---

@test "args: --pr flag triggers standalone review with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr 42
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10 from state.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
  ! grep -q " 10 " "$GH_MOCK_DIR/gh-calls.log"
  ! grep -q " 10$" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: --pr-number flag triggers standalone review with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr-number 42
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: --pr flag before project dir works with correct PR" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --pr 42 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Verify gh was called with PR 42, not the cron-mode PR 10.
  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  grep -q "42" "$GH_MOCK_DIR/gh-calls.log"
}

@test "args: bare positional PR number is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
  [[ "$output" == *"--pr NUMBER"* ]]
}

@test "args: extra positional args are rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" extra_arg
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}

@test "args: account number as positional arg is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}

@test "args: cron mode with no extra args works" {
  # State is pending so cron review will skip — exits cleanly.
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "args: --pr without value prints error" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a PR number"* ]]
}

@test "args: --help prints usage" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--pr NUMBER"* ]]
  [[ "$output" == *"Standalone mode"* ]]
}

@test "args: unknown flag is rejected" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --unknown
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

# --- Numeric Validation on --pr Value ---

@test "args: --pr foo exits non-zero with validation error" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
  [[ "$output" == *"'foo'"* ]]
}

@test "args: --pr empty string exits non-zero with validation error" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
}

@test "args: --pr 42 succeeds with valid integer" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "10"
  AUTOPILOT_REVIEWERS="general"

  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr 42
  [ "$status" -eq 0 ]
}

@test "args: --pr with flag-like value exits non-zero" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr --help
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
  [[ "$output" == *"'--help'"* ]]
}

@test "args: --pr with mixed alphanumeric exits non-zero" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr 42abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
  [[ "$output" == *"'42abc'"* ]]
}

@test "args: --pr-number with non-numeric exits non-zero" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr-number xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
  [[ "$output" == *"'xyz'"* ]]
}

@test "args: --pr 0 exits non-zero (PR numbers start at 1)" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" "$TEST_PROJECT_DIR" --pr 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR number must be a positive integer"* ]]
  [[ "$output" == *"'0'"* ]]
}

# --- Usage Synopsis ---

@test "usage: shows PROJECT_DIR as optional" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PROJECT_DIR]"* ]]
}

@test "usage: mentions default directory" {
  run "$BATS_TEST_DIRNAME/../bin/autopilot-review" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"defaults to"* ]]
}
