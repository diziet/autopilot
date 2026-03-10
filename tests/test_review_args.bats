#!/usr/bin/env bats
# Tests for review entry — numeric validation, usage synopsis,
# reviewer retry limit, and reviewer JSON saving.
# Split from test_review_standalone.bats for parallel execution.

load helpers/review_entry_setup

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

# --- Reviewer Retry Limit ---

@test "_is_reviewer_paused returns false when retry count is 0" {
  run _is_reviewer_paused "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "_is_reviewer_paused returns false at max retries (boundary)" {
  # With -gt, at exactly max the reviewer should still try once more.
  AUTOPILOT_MAX_REVIEWER_RETRIES=3
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3
  run _is_reviewer_paused "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "_is_reviewer_paused returns true when over max retries" {
  AUTOPILOT_MAX_REVIEWER_RETRIES=3
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 4
  run _is_reviewer_paused "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

@test "_is_reviewer_paused logs CRITICAL when paused" {
  AUTOPILOT_MAX_REVIEWER_RETRIES=2
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3
  _is_reviewer_paused "$TEST_PROJECT_DIR" || true
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[CRITICAL]"* ]]
  [[ "$log_content" == *"Reviewer paused"* ]]
}

@test "_track_reviewer_failure increments reviewer retry counter" {
  _track_reviewer_failure "$TEST_PROJECT_DIR"
  local val
  val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "1" ]
}

@test "cron review resets reviewer retries on success" {
  # Set up pr_open state with a valid PR number.
  write_state "$TEST_PROJECT_DIR" "status" "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  # Pre-set some retries.
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3

  _run_cron_review "$TEST_PROJECT_DIR" || true

  # On successful review, counter should be reset.
  local val
  val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

# --- Reviewer JSON Saving ---

# Add a reviewer result entry to a result directory.
_add_reviewer_result() {
  local result_dir="$1" persona="$2" json="$3" exit_code="$4"
  local output_file="$BATS_TEST_TMPDIR/output_${persona}"
  echo "$json" > "$output_file"
  printf '%s\n%s\n' "$output_file" "$exit_code" > "${result_dir}/${persona}.meta"
}

@test "reviewer JSON files are saved to logs directory after review run" {
  write_state "$TEST_PROJECT_DIR" "current_task" "5"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  _add_reviewer_result "$result_dir" "general" \
    '{"result":"NO_ISSUES_FOUND","session_id":"s1"}' "0"
  _add_reviewer_result "$result_dir" "security" \
    '{"result":"Found issue","session_id":"s2"}' "0"

  _record_reviewer_usage "$TEST_PROJECT_DIR" "$result_dir"

  local logs_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  [ -f "${logs_dir}/reviewer-general-task-5.json" ]
  [ -f "${logs_dir}/reviewer-security-task-5.json" ]
  [[ "$(cat "${logs_dir}/reviewer-general-task-5.json")" == *"NO_ISSUES_FOUND"* ]]
  [[ "$(cat "${logs_dir}/reviewer-security-task-5.json")" == *"Found issue"* ]]
}

@test "reviewer JSON files are not saved for failed reviewers" {
  write_state "$TEST_PROJECT_DIR" "current_task" "7"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  _add_reviewer_result "$result_dir" "general" '{"result":"OK","session_id":"s1"}' "0"
  _add_reviewer_result "$result_dir" "security" '{"error":"timeout"}' "124"

  _record_reviewer_usage "$TEST_PROJECT_DIR" "$result_dir"

  local logs_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  [ -f "${logs_dir}/reviewer-general-task-7.json" ]
  [ ! -f "${logs_dir}/reviewer-security-task-7.json" ]
}

@test "saved reviewer JSON files match pattern expected by perf-summary" {
  write_state "$TEST_PROJECT_DIR" "current_task" "10"
  AUTOPILOT_REVIEWERS="general"

  _execute_review_cycle "$TEST_PROJECT_DIR" "42" "standalone"

  local logs_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  local count=0
  for f in "${logs_dir}"/reviewer-*-task-10.json; do
    [ -f "$f" ] && count=$((count + 1))
  done
  [ "$count" -ge 1 ]
}

@test "cron review skips when reviewer retry limit exceeded" {
  write_state "$TEST_PROJECT_DIR" "status" "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_MAX_REVIEWER_RETRIES=2
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3

  local rc=0
  _run_cron_review "$TEST_PROJECT_DIR" || rc=$?
  [ "$rc" -eq "$REVIEW_ERROR" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}
