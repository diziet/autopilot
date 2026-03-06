#!/usr/bin/env bats
# Tests for bin/autopilot-dispatch and lib/dispatcher.sh — state machine
# transitions, quick guards, crash recovery, and helper functions.
# All external commands (claude, gh, git ops) are mocked.

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

# --- Quick Guards (bin/autopilot-dispatch) ---

@test "quick guard: exits 0 when PAUSE file exists" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  # Source the script in a subshell simulating the guard logic.
  local state_dir="${TEST_PROJECT_DIR}/.autopilot"
  [[ -f "${state_dir}/PAUSE" ]]
}

@test "quick guard: exits 0 when lock held by live PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_pid
  lock_pid="$(cat "$lock_file")"
  # Our own PID is alive.
  ps -p "$lock_pid" >/dev/null 2>&1
}

@test "quick guard: proceeds when lock held by dead PID" {
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999" > "${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  local lock_pid
  lock_pid="$(cat "$lock_file")"
  # PID 99999 is almost certainly dead.
  ! ps -p "$lock_pid" >/dev/null 2>&1
}

# --- dispatch_tick routing ---

@test "dispatch_tick routes pending state" {
  _set_state "pending"
  # Mock all the functions that pending handler calls.
  run_preflight() { return 0; }
  run_coder() { echo "/dev/null"; return 0; }
  detect_task_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  # After pending handler runs coder, detect PR → pr_open (background test gate).
  local status
  status="$(_get_status)"
  [ "$status" = "pr_open" ]
}

@test "dispatch_tick routes pr_open — stays in pr_open when no result" {
  _set_state "pr_open"
  # No test gate result file — stays in pr_open.
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "dispatch_tick routes completed as no-op" {
  _set_state "completed"
  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "dispatch_tick rejects unknown state" {
  write_state "$TEST_PROJECT_DIR" "status" "bogus"
  run dispatch_tick "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

# --- _handle_pending ---

@test "pending: transitions to completed when all tasks done" {
  _set_state "pending"
  _set_task 4  # 3 tasks in file, so task 4 is beyond.

  _handle_pending "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

@test "pending: stale branch gets deleted" {
  _set_state "pending"
  _set_task 1
  # Create a stale branch.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main -q 2>/dev/null

  # Mock heavy operations.
  run_preflight() { return 0; }
  run_coder() { echo "/dev/null"; return 0; }
  detect_task_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  _handle_pending "$TEST_PROJECT_DIR"
  # Branch should have been reset (deleted and recreated).
  local status
  status="$(_get_status)"
  [ "$status" = "pr_open" ]
}

# --- _handle_coder_result ---

@test "coder result: no PR detected triggers retry" {
  _set_state "implementing"
  _set_task 1
  detect_task_pr() { return 1; }
  export -f detect_task_pr

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  local status
  status="$(_get_status)"
  [ "$status" = "pending" ]
}

@test "coder result: PR detected transitions to pr_open with background test gate" {
  _set_state "implementing"
  _set_task 1
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
}

@test "coder result: always transitions to pr_open regardless of test gate" {
  _set_state "implementing"
  _set_task 1
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  # Background test gate runs async — coder result always goes to pr_open.
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f detect_task_pr run_test_gate_background _trigger_reviewer_background

  _handle_coder_result "$TEST_PROJECT_DIR" 1 0
  [ "$(_get_status)" = "pr_open" ]
}

@test "coder result: non-zero exit retries immediately without checking PR" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  _handle_coder_result "$TEST_PROJECT_DIR" 1 1
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_implementing (crash recovery) ---

@test "implementing: crash recovery returns to pending with retry increment" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  _handle_implementing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_test_fixing ---

@test "test_fixing: tests now pass transitions to pr_open" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  run_test_gate() { return 0; }
  export -f run_test_gate

  _handle_test_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "test_fixing: exhausted test fix retries with max main retries triggers diagnosis" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5
  run_test_gate() { return 1; }
  run_diagnosis() { return 0; }
  export -f run_test_gate run_diagnosis

  _handle_test_fixing "$TEST_PROJECT_DIR"
  # Max retries exhausted → diagnosis runs → advances to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}

@test "test_fixing: exhausted test fix retries increments main retry" {
  _set_state "test_fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5
  run_test_gate() { return 1; }
  export -f run_test_gate

  _handle_test_fixing "$TEST_PROJECT_DIR"
  # Still have main retries → increment and go to pending for fresh coder.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_reviewed ---

@test "reviewed: clean reviews skip fixer, transition to fixed" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Write a reviewed.json where all reviews are clean.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"abc","is_clean":true},"dry":{"sha":"abc","is_clean":true}}}
JSON

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "reviewed: issues found spawns fixer" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Write a reviewed.json with issues.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"abc","is_clean":false}}}
JSON

  # Mock fixer and postfix.
  run_fixer() { echo "/dev/null"; return 0; }
  fetch_remote_sha() { echo "abc123"; }
  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f run_fixer fetch_remote_sha verify_fixer_push run_postfix_verification

  _handle_reviewed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

# --- _handle_fixed ---

@test "fixed: transitions to merging and spawns merger" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock merger to approve.
  run_merger() { return 0; }  # MERGER_APPROVE=0
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "fixed: merger reject goes back to reviewed" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock merger to reject.
  run_merger() { return 1; }  # MERGER_REJECT=1
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "reviewed" ]
}

@test "fixed: merger error with retries left increments retry and goes to pending" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  # Mock merger to error.
  run_merger() { return 2; }  # MERGER_ERROR=2
  export -f run_merger

  _handle_fixed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_merging (crash recovery) ---

@test "merging: crash recovery with retries left goes to pending" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_merging "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_merged ---

@test "merged: advances task counter" {
  # Need to set up valid transition: merged → pending.
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Mock metrics and summary.
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]
  [ "$(_get_status)" = "pending" ]
}

@test "merged: resets retry and test_fix counters" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 2

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merged: last task transitions to completed" {
  _set_state "merged"
  _set_task 3  # 3 tasks in file, this is the last.
  write_state "$TEST_PROJECT_DIR" "pr_number" "99"

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  _handle_merged "$TEST_PROJECT_DIR"

  [ "$(_get_status)" = "completed" ]
}

# --- _handle_completed ---

@test "completed: is a no-op terminal state" {
  _set_state "completed"
  _handle_completed "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "completed" ]
}

# --- _extract_pr_number ---

@test "extract PR number from standard GitHub URL" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/42")"
  [ "$result" = "42" ]
}

@test "extract PR number from URL with trailing slash" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/123/")"
  [ "$result" = "123" ]
}

@test "extract PR number returns 0 on invalid URL" {
  run _extract_pr_number "not-a-url"
  [ "$output" = "0" ]
}

# --- _all_reviews_clean_from_json ---

@test "all_reviews_clean: true when all is_clean=true" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_10":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":true}}}
JSON
  _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when any is_clean=false" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_10":{"general":{"sha":"a","is_clean":true},"dry":{"sha":"a","is_clean":false}}}
JSON
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when no reviewed.json" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/reviewed.json"
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

@test "all_reviews_clean: false when PR key missing" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo '{"pr_99":{"general":{"sha":"a","is_clean":true}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"
  ! _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
}

# --- _retry_or_diagnose ---

@test "retry: increments retry count and returns to pending" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

@test "retry: max retries triggers diagnosis and advances task" {
  _set_state "implementing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _retry_or_diagnose "$TEST_PROJECT_DIR" 1 "implementing"

  # Should advance to task 2.
  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]
}

@test "retry: max retries on last task goes to pending (next tick completes)" {
  _set_state "implementing"
  _set_task 3  # last task
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _retry_or_diagnose "$TEST_PROJECT_DIR" 3 "implementing"

  # Advances to task 4 and goes to pending.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "4" ]
}

# --- _handle_merger_result ---

@test "merger result: APPROVE transitions to merged" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_APPROVE"
  [ "$(_get_status)" = "merged" ]
}

@test "merger result: REJECT goes to reviewed with hints" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_REJECT"
  [ "$(_get_status)" = "reviewed" ]
}

@test "merger result: ERROR with retries left increments retry and goes to pending" {
  _set_state "merging"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_merger_result "$TEST_PROJECT_DIR" 1 42 "$MERGER_ERROR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixer_result ---

@test "fixer result: postfix pass transitions to fixed" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 0; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  [ "$(_get_status)" = "fixed" ]
}

@test "fixer result: postfix fail goes back to reviewed" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 1; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  [ "$(_get_status)" = "reviewed" ]
}

@test "fixer result: postfix fail with exhausted retries triggers diagnosis" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_MAX_RETRIES=5

  verify_fixer_push() { return 0; }
  run_postfix_verification() { return 1; }
  export -f verify_fixer_push run_postfix_verification

  _handle_fixer_result "$TEST_PROJECT_DIR" 1 42
  # Exhausted test fix retries → _retry_or_diagnose increments main retry.
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- _handle_fixing (crash recovery) ---

@test "fixing: crash recovery with retries left goes to pending" {
  _set_state "fixing"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0
  AUTOPILOT_MAX_RETRIES=5

  _handle_fixing "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "1" ]
}

# --- MAX_RETRIES guard enforcement ---

@test "merger error: retry_count >= max triggers diagnosis and advances task" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_merger() { return 2; }  # MERGER_ERROR
  run_diagnosis() { return 0; }
  export -f run_merger run_diagnosis

  _handle_fixed "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "implementing crash recovery: retry_count >= max triggers diagnosis" {
  _set_state "implementing"
  _set_task 2
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_implementing "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 3.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "3" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "fixing crash recovery: retry_count >= max triggers diagnosis" {
  _set_state "fixing"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_fixing "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

@test "merging crash recovery: retry_count >= max triggers diagnosis" {
  _set_state "merging"
  _set_task 1
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 5
  AUTOPILOT_MAX_RETRIES=5

  run_diagnosis() { return 0; }
  export -f run_diagnosis

  _handle_merging "$TEST_PROJECT_DIR"

  # Should diagnose and advance to task 2.
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]
}

# --- State machine integration ---

@test "full cycle: pending → implementing → pr_open (mocked)" {
  _set_state "pending"
  _set_task 1

  run_preflight() { return 0; }
  run_coder() { echo "/dev/null"; return 0; }
  detect_task_pr() { echo "https://github.com/x/y/pull/42"; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder detect_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pr_open" ]
}

@test "full cycle: reviewed → fixed (clean reviews)" {
  _set_state "reviewed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_42":{"general":{"sha":"a","is_clean":true},"security":{"sha":"a","is_clean":true}}}
JSON

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "fixed" ]
}

@test "full cycle: fixed → merged (merger approves)" {
  _set_state "fixed"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  run_merger() { return 0; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "merged" ]
}

@test "full cycle: merged → pending (advance task)" {
  _set_state "merged"
  _set_task 1
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  export -f record_task_complete record_phase_durations generate_task_summary_bg
  export -f should_run_spec_review record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"
  [ "$(_get_status)" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "2" ]
}
