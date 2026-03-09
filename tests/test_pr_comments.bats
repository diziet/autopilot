#!/usr/bin/env bats
# Tests for lib/pr-comments.sh — PR status comment posting for pipeline events.
# Covers: test gate failure comments, fixer result comments, truncation,
# and non-fatal gh API failure handling.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  GH_CALL_LOG="${TEST_PROJECT_DIR}/gh_calls.log"
  TIMEOUT_ARGS_LOG="${TEST_PROJECT_DIR}/timeout_args.log"

  # Source dependencies.
  source "$BATS_TEST_DIRNAME/../lib/config.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  source "$BATS_TEST_DIRNAME/../lib/pr-comments.sh"

  # Initialize state directory.
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot"

  # Mock gh to log calls and succeed.
  _mock_gh_logging
  _mock_timeout
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"
}

# --- Test Helpers ---

# Mock gh CLI that logs calls for verification.
_mock_gh_logging() {
  local log_file="$GH_CALL_LOG"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
echo "\$*" >> "${log_file}"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Mock gh CLI that always fails.
_mock_gh_failing() {
  local log_file="$GH_CALL_LOG"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
echo "\$*" >> "${log_file}"
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Mock timeout that logs its first arg (the timeout value) and runs the command.
_mock_timeout() {
  local log_file="$TIMEOUT_ARGS_LOG"
  cat > "${TEST_MOCK_BIN}/timeout" << MOCK
#!/bin/bash
echo "\$1" >> "${log_file}"
shift
exec "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

# Create test output log with given content.
_create_test_output() {
  local content="$1"
  echo "$content" > "${TEST_PROJECT_DIR}/.autopilot/test_gate_output.log"
}

# Create test output log with N lines.
_create_test_output_lines() {
  local count="$1"
  local i
  for (( i=1; i<=count; i++ )); do
    echo "test output line ${i}"
  done > "${TEST_PROJECT_DIR}/.autopilot/test_gate_output.log"
}

# Create fixer commits on a branch for git log testing.
_create_fixer_commits() {
  local count="${1:-2}"
  local i
  for (( i=1; i<=count; i++ )); do
    echo "fix-${i}" >> "$TEST_PROJECT_DIR/fixfile.txt"
    git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
    git -C "$TEST_PROJECT_DIR" commit -m "fix: change ${i}" -q
  done
}

# --- Non-fatal comment posting (via post_pr_comment || true) ---

@test "post_test_failure_comment calls gh pr comment with correct args" {
  _create_test_output "FAILED: test_foo"
  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  # Verify gh was called with pr comment.
  [ -f "$GH_CALL_LOG" ]
  local call
  call="$(cat "$GH_CALL_LOG")"
  [[ "$call" == *"pr comment"* ]]
  [[ "$call" == *"42"* ]]
  [[ "$call" == *"--repo"* ]]
  [[ "$call" == *"testowner/testrepo"* ]]
}

@test "post_test_failure_comment passes AUTOPILOT_TIMEOUT_GH to timeout" {
  AUTOPILOT_TIMEOUT_GH=5
  _create_test_output "FAILED"
  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"
  [ -f "$TIMEOUT_ARGS_LOG" ]
  grep -q "^5$" "$TIMEOUT_ARGS_LOG"
}

@test "post_test_failure_comment returns 0 on gh failure (non-fatal)" {
  _mock_gh_failing
  _create_test_output "FAILED"
  run post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
}

@test "post_test_failure_comment returns 0 when repo slug unavailable" {
  # Remove the git remote to make get_repo_slug fail.
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true
  _create_test_output "FAILED"
  run post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
  # gh should NOT have been called.
  [ ! -f "$GH_CALL_LOG" ] || [ ! -s "$GH_CALL_LOG" ]
}

# --- post_test_failure_comment body content ---

@test "post_test_failure_comment includes exit code in body" {
  _create_test_output "FAILED: test_foo"

  # Capture the comment body by intercepting gh.
  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  [ -f "$body_file" ]
  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"Test Gate Failed"* ]]
  [[ "$body" == *"Exit code"* ]]
  [[ "$body" == *"\`1\`"* ]]
}

@test "post_test_failure_comment includes test output" {
  _create_test_output "ERROR: assertion failed in test_bar"

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"assertion failed"* ]]
}

@test "post_test_failure_comment works without output log" {
  # No test_gate_output.log file exists.
  run post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
  [ -f "$GH_CALL_LOG" ]
}

# --- Truncation ---

@test "test failure comment truncates output to AUTOPILOT_TEST_OUTPUT_TAIL" {
  AUTOPILOT_TEST_OUTPUT_TAIL=5
  _create_test_output_lines 100

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "$body_file")"
  # Should contain lines from end (tail -n 5), not from start.
  [[ "$body" == *"test output line 100"* ]]
  [[ "$body" == *"test output line 96"* ]]
  # Should NOT contain early lines.
  [[ "$body" != *"test output line 1"$'\n'* ]]
}

@test "test failure comment enforces max 100 lines total" {
  # Set a very large tail to exceed the 100-line limit.
  AUTOPILOT_TEST_OUTPUT_TAIL=200
  _create_test_output_lines 200

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "$body_file")"
  local line_count
  line_count="$(echo "$body" | wc -l | tr -d ' ')"
  # Total comment (including header/footer) should not exceed 100 lines.
  [ "$line_count" -le 100 ]
}

@test "test failure comment includes default 80 lines of output" {
  # Verify the default AUTOPILOT_TEST_OUTPUT_TAIL=80 is not silently capped.
  AUTOPILOT_TEST_OUTPUT_TAIL=80
  _create_test_output_lines 100

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "$body_file")"
  # With 80-line tail from 100-line file, line 21 should be present (100-80+1).
  [[ "$body" == *"test output line 21"* ]]
  # Line 20 should NOT be present (outside the 80-line tail).
  [[ "$body" != *"test output line 20"$'\n'* ]]
}

# --- post_fixer_result_comment ---

@test "post_fixer_result_comment posts with test pass status" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 2

  run post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"
  [ "$status" -eq 0 ]
  [ -f "$GH_CALL_LOG" ]
}

@test "fixer result comment shows passed when tests pass" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 1

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"

  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"Fixer Completed"* ]]
  [[ "$body" == *"Passed"* ]]
  [[ "$body" == *"fix: change 1"* ]]
}

@test "fixer result comment shows failed when tests fail" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 1

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "false"

  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"Failed"* ]]
}

@test "fixer result comment lists commits between SHAs" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 3

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"

  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"fix: change 1"* ]]
  [[ "$body" == *"fix: change 2"* ]]
  [[ "$body" == *"fix: change 3"* ]]
}

@test "fixer result comment handles no commits gracefully" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  # No new commits.

  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "false"

  local body
  body="$(cat "$body_file")"
  [[ "$body" == *"No new commits"* ]]
}

# --- gh API failure is non-fatal ---

@test "test failure comment continues on gh API failure" {
  _mock_gh_failing
  _create_test_output "FAILED"
  run post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
}

@test "fixer result comment continues on gh API failure" {
  _mock_gh_failing
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  run post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"
  [ "$status" -eq 0 ]
}

# --- Fixer summary from agent JSON ---

# Create a mock fixer output JSON with a result summary.
_create_fixer_json() {
  local task_number="$1"
  local result_text="$2"
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  mkdir -p "$log_dir"
  jq -n --arg r "$result_text" '{"result":$r}' \
    > "${log_dir}/fixer-task-${task_number}.json"
}

# Helper: capture the comment body posted by gh.
_setup_body_capture() {
  local body_file="${TEST_PROJECT_DIR}/captured_body.txt"
  cat > "${TEST_MOCK_BIN}/gh" << MOCK
#!/bin/bash
for arg in "\$@"; do
  if [ "\$capture_next" = "1" ]; then
    echo "\$arg" > "${body_file}"
    break
  fi
  [ "\$arg" = "--body" ] && capture_next=1
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

@test "fixer result comment includes agent summary from JSON" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 1
  _create_fixer_json 5 "Fixed the missing import and updated tests."
  _setup_body_capture

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true" "5"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Fixer summary"* ]]
  [[ "$body" == *"Fixed the missing import"* ]]
}

@test "fixer result comment works without agent JSON" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 1
  _setup_body_capture

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true" "99"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Fixer Completed"* ]]
  [[ "$body" != *"Fixer summary"* ]]
}

@test "fixer result comment includes test failures when tests fail" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_test_output "ok 1 test_foo
ok 2 test_bar
not ok 3 test_baz: expected 0 got 1
not ok 4 test_qux: assertion failed"
  _setup_body_capture

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "false"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Failing tests"* ]]
  [[ "$body" == *"not ok 3"* ]]
  [[ "$body" == *"not ok 4"* ]]
}

@test "fixer result comment omits test failures when tests pass" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_test_output "ok 1 test_foo
not ok 2 test_bar"
  _setup_body_capture

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" != *"Failing tests"* ]]
}

# --- Test summary in PR comments ---

@test "test failure comment includes bats test summary" {
  _create_test_output "ok 1 test_foo
ok 2 test_bar
not ok 3 test_baz"
  _setup_body_capture

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Tests: 3 total, 2 passed, 1 failed"* ]]
}

@test "test failure comment includes pytest test summary" {
  _create_test_output "test_foo.py::test_a PASSED
test_foo.py::test_b FAILED
===== 1 passed, 1 failed in 2.50s ====="
  _setup_body_capture

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "1"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Tests: 2 total, 1 passed, 1 failed"* ]]
}

@test "test failure comment shows timeout summary for exit code 124" {
  _create_test_output "ok 1 test_one
ok 2 test_two"
  AUTOPILOT_TIMEOUT_TEST_GATE=300
  _setup_body_capture

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "124"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"killed by timeout after 300s"* ]]
}

@test "test failure comment shows timeout summary with no output for exit 124" {
  # No test output log — timeout with no parseable output.
  AUTOPILOT_TIMEOUT_TEST_GATE=600
  _setup_body_capture

  post_test_failure_comment "$TEST_PROJECT_DIR" "42" "124"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"killed by timeout after 600s"* ]]
}

@test "fixer result comment includes test summary from output log" {
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  _create_fixer_commits 1
  _create_test_output "ok 1 test_one
ok 2 test_two
ok 3 test_three"
  _setup_body_capture

  post_fixer_result_comment "$TEST_PROJECT_DIR" "42" \
    "$sha_before" "true"

  local body
  body="$(cat "${TEST_PROJECT_DIR}/captured_body.txt")"
  [[ "$body" == *"Tests: 3 total, 3 passed, 0 failed"* ]]
}
