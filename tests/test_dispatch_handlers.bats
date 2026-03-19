#!/usr/bin/env bats
# Tests for post-merge session summary comment (Task 168).
# Covers: session summary posting, missing/malformed files, comment failure,
# and all agent roles.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/dispatch-helpers.sh"
source "$BATS_TEST_DIRNAME/../lib/pr-comments.sh"
source "$BATS_TEST_DIRNAME/../lib/state.sh"
source "$BATS_TEST_DIRNAME/../lib/config.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
}

# --- Helper: mock post_pr_comment and capture the body ---
_mock_pr_comment_capture() {
  comment_body=""
  post_pr_comment() { comment_body="$3"; return 0; }
}

# --- Helper: create agent session JSON files ---

# Create a session JSON file for an agent role.
# Args: role task_number session_id [walltime_seconds]
_create_session_file() {
  local role="$1"
  local task_number="$2"
  local session_id="$3"
  local walltime="${4:-}"
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"

  mkdir -p "$log_dir"
  echo "{\"session_id\":\"${session_id}\",\"result\":\"done\"}" \
    > "${log_dir}/${role}-task-${task_number}.json"

  if [[ -n "$walltime" ]]; then
    echo "$walltime" > "${log_dir}/${role}-task-${task_number}.walltime"
  fi
}

# --- Session summary is posted after successful merge ---

@test "session summary is posted after successful merge" {
  _create_session_file "coder" "1" "sess-coder-abc" "120"
  _mock_pr_comment_capture

  post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"

  # Verify the comment contains expected content.
  [[ "$comment_body" == *"Agent Session Summary"* ]]
  [[ "$comment_body" == *"coder"* ]]
  [[ "$comment_body" == *"sess-coder-abc"* ]]
  [[ "$comment_body" == *"2m 0s"* ]]
}

# --- Missing or malformed session files are skipped gracefully ---

@test "missing session files produce no comment" {
  # No JSON files created — log dir is empty.
  run post_session_summary_comment "$TEST_PROJECT_DIR" "42" "99"
  [ "$status" -eq 0 ]
}

@test "malformed JSON files are skipped gracefully" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  mkdir -p "$log_dir"
  echo "not valid json" > "${log_dir}/coder-task-1.json"

  # Should succeed (skip the bad file) rather than fail.
  run post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
}

@test "JSON without session_id is skipped" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  mkdir -p "$log_dir"
  echo '{"result":"done"}' > "${log_dir}/coder-task-1.json"

  run post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
}

# --- Comment failure logs a warning but doesn't block the pipeline ---

@test "comment failure logs warning but returns success" {
  _create_session_file "coder" "1" "sess-abc"

  post_pr_comment() { return 1; }

  run post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"
  [ "$status" -eq 0 ]
}

# --- All agent roles are included when present ---

@test "all agent roles included when present" {
  _create_session_file "coder" "5" "sess-coder-1" "300"
  _create_session_file "reviewer-eng-review" "5" "sess-rev-eng" "180"
  _create_session_file "reviewer-qa-review" "5" "sess-rev-qa" "90"
  _create_session_file "fixer" "5" "sess-fixer-1" "60"
  _create_session_file "merger" "5" "sess-merger-1" "30"

  _mock_pr_comment_capture

  post_session_summary_comment "$TEST_PROJECT_DIR" "100" "5"

  # All roles present.
  [[ "$comment_body" == *"coder"* ]]
  [[ "$comment_body" == *"reviewer-eng-review"* ]]
  [[ "$comment_body" == *"reviewer-qa-review"* ]]
  [[ "$comment_body" == *"fixer"* ]]
  [[ "$comment_body" == *"merger"* ]]

  # All session IDs present.
  [[ "$comment_body" == *"sess-coder-1"* ]]
  [[ "$comment_body" == *"sess-rev-eng"* ]]
  [[ "$comment_body" == *"sess-rev-qa"* ]]
  [[ "$comment_body" == *"sess-fixer-1"* ]]
  [[ "$comment_body" == *"sess-merger-1"* ]]
}

@test "duration displays correctly without walltime file" {
  _create_session_file "coder" "1" "sess-abc"
  _mock_pr_comment_capture

  post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"

  # Duration should show "-" when no walltime file.
  [[ "$comment_body" == *"| - |"* ]]
}

@test "duration formats seconds under 60 correctly" {
  _create_session_file "coder" "1" "sess-abc" "45"
  _mock_pr_comment_capture

  post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"

  [[ "$comment_body" == *"45s"* ]]
}

@test "session summary skips files for other tasks" {
  _create_session_file "coder" "1" "sess-task1"
  _create_session_file "coder" "2" "sess-task2"
  _mock_pr_comment_capture

  post_session_summary_comment "$TEST_PROJECT_DIR" "42" "1"

  [[ "$comment_body" == *"sess-task1"* ]]
  [[ "$comment_body" != *"sess-task2"* ]]
}
