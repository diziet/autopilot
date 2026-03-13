#!/usr/bin/env bats
# Edge case tests for lib/dispatch-helpers.sh — PR number extraction,
# clean review detection, reviewed status clearing, network retry handling,
# and retry/diagnosis logic edge cases.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/dispatch-helpers.sh"
source "$BATS_TEST_DIRNAME/../lib/state.sh"
source "$BATS_TEST_DIRNAME/../lib/config.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  # Initialize state.
  init_pipeline "$TEST_PROJECT_DIR"
}

# --- _extract_pr_number edge cases ---

@test "extract PR number from URL with query params" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/99?diff=split")"
  [ "$result" = "99" ]
}

@test "extract PR number from URL with fragment" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/55#issuecomment-123")"
  [ "$result" = "55" ]
}

@test "extract PR number handles large PR numbers" {
  local result
  result="$(_extract_pr_number "https://github.com/owner/repo/pull/99999")"
  [ "$result" = "99999" ]
}

@test "extract PR number from empty string returns 0" {
  run _extract_pr_number ""
  [ "$output" = "0" ]
  [ "$status" -eq 1 ]
}

@test "extract PR number from numeric-only string" {
  local result
  result="$(_extract_pr_number "42")"
  [ "$result" = "42" ]
}

# --- _clear_reviewed_status ---

@test "clear_reviewed_status removes PR key from reviewed.json" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" <<'JSON'
{"pr_100": {"reviewer1": {"is_clean": true}}, "pr_200": {"reviewer1": {"is_clean": false}}}
JSON

  _clear_reviewed_status "$TEST_PROJECT_DIR" "100"

  local has_key
  has_key="$(jq 'has("pr_100")' "$TEST_PROJECT_DIR/.autopilot/reviewed.json")"
  [ "$has_key" = "false" ]

  # Other PR keys should remain.
  local other_key
  other_key="$(jq 'has("pr_200")' "$TEST_PROJECT_DIR/.autopilot/reviewed.json")"
  [ "$other_key" = "true" ]
}

@test "clear_reviewed_status handles missing reviewed.json" {
  run _clear_reviewed_status "$TEST_PROJECT_DIR" "100"
  [ "$status" -eq 0 ]
}

@test "clear_reviewed_status handles PR key not in file" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo '{"pr_1": {"r": {"is_clean": true}}}' \
    > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"

  run _clear_reviewed_status "$TEST_PROJECT_DIR" "999"
  [ "$status" -eq 0 ]
}

# --- _all_reviews_clean_from_json edge cases ---

@test "all_reviews_clean: empty reviewers array returns false" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo '{"pr_1": {}}' > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"

  run _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "1"
  [ "$status" -eq 1 ]
}

@test "all_reviews_clean: mixed clean and not-clean returns false" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" <<'JSON'
{"pr_5": {"r1": {"is_clean": true}, "r2": {"is_clean": false}}}
JSON

  run _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "5"
  [ "$status" -eq 1 ]
}

@test "all_reviews_clean: multiple clean reviewers returns true" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" <<'JSON'
{"pr_10": {"r1": {"is_clean": true}, "r2": {"is_clean": true}, "r3": {"is_clean": true}}}
JSON

  run _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "10"
  [ "$status" -eq 0 ]
}

@test "all_reviews_clean: corrupt JSON returns false" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "not json" > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"

  run _all_reviews_clean_from_json "$TEST_PROJECT_DIR" "1"
  [ "$status" -eq 1 ]
}

# --- _handle_network_retry ---

@test "network retry: pauses pipeline when network retries exhausted" {
  AUTOPILOT_MAX_NETWORK_RETRIES=2

  # Set network retries to the max.
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 2

  _handle_network_retry "$TEST_PROJECT_DIR" "1" "implementing"

  # PAUSE file should exist.
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/PAUSE")"
  [[ "$content" == *"Network retries exhausted"* ]]
}

@test "network retry: increments counter and returns to pending" {
  AUTOPILOT_MAX_NETWORK_RETRIES=5
  # Must be in implementing state for valid transition to pending.
  write_state "$TEST_PROJECT_DIR" "status" "implementing"

  _handle_network_retry "$TEST_PROJECT_DIR" "3" "implementing"

  local net_count
  net_count="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$net_count" = "1" ]

  local status_val
  status_val="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status_val" = "pending" ]
}

# --- _retry_or_diagnose edge cases ---

@test "retry_or_diagnose: first failure increments retry" {
  # Must be in implementing state for valid transition to pending.
  write_state "$TEST_PROJECT_DIR" "status" "implementing"

  # Mock external dependencies.
  _get_recent_failure_output() { echo "normal error"; }
  _is_network_error() { return 1; }

  _retry_or_diagnose "$TEST_PROJECT_DIR" "1" "implementing"

  local retry_count
  retry_count="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$retry_count" = "1" ]

  local status_val
  status_val="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status_val" = "pending" ]
}

@test "retry_or_diagnose: network error does not increment retry count" {
  # Must be in implementing state for valid transition to pending.
  write_state "$TEST_PROJECT_DIR" "status" "implementing"

  _get_recent_failure_output() { echo "Connection refused"; }
  _is_network_error() { return 0; }
  AUTOPILOT_MAX_NETWORK_RETRIES=10

  _retry_or_diagnose "$TEST_PROJECT_DIR" "1" "implementing"

  local retry_count
  retry_count="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$retry_count" = "0" ]

  local net_count
  net_count="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$net_count" = "1" ]
}

@test "retry_or_diagnose: resets network counter on non-network error" {
  # Must be in implementing state for valid transition to pending.
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  # Set a previous network retry count.
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 3

  _get_recent_failure_output() { echo "normal error"; }
  _is_network_error() { return 1; }

  _retry_or_diagnose "$TEST_PROJECT_DIR" "1" "implementing"

  local net_count
  net_count="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$net_count" = "0" ]
}

# --- _advance_task ---

@test "advance_task: resets all counters for next task" {
  write_state "$TEST_PROJECT_DIR" "status" "merged"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 2
  write_state_num "$TEST_PROJECT_DIR" "network_retry_count" 5

  # Mock tasks file detection.
  detect_tasks_file() { echo ""; }

  _advance_task "$TEST_PROJECT_DIR" "1"

  local retry
  retry="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$retry" = "0" ]

  local test_fix
  test_fix="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$test_fix" = "0" ]

  local net_retry
  net_retry="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$net_retry" = "0" ]
}

@test "advance_task: clears pr_number so it does not leak to next task" {
  write_state "$TEST_PROJECT_DIR" "status" "merged"
  write_state "$TEST_PROJECT_DIR" "pr_number" "152"
  write_state "$TEST_PROJECT_DIR" "draft_pr_number" "152"
  write_state "$TEST_PROJECT_DIR" "sha_before_fix" "abc123"

  detect_tasks_file() { echo ""; }

  _advance_task "$TEST_PROJECT_DIR" "1"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ -z "$pr_number" ]

  local draft
  draft="$(read_state "$TEST_PROJECT_DIR" "draft_pr_number")"
  [ -z "$draft" ]

  local sha
  sha="$(read_state "$TEST_PROJECT_DIR" "sha_before_fix")"
  [ -z "$sha" ]
}

@test "advance_task: skips when status is not merged" {
  # Set status to something other than merged.
  write_state "$TEST_PROJECT_DIR" "status" "implementing"

  detect_tasks_file() { echo ""; }

  _advance_task "$TEST_PROJECT_DIR" "1"

  # Task should NOT be advanced.
  local task
  task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$task" = "1" ]
}

@test "advance_task: increments current_task by 1" {
  write_state "$TEST_PROJECT_DIR" "status" "merged"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 5

  detect_tasks_file() { echo ""; }

  _advance_task "$TEST_PROJECT_DIR" "5"

  local task
  task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$task" = "6" ]
}

# --- _handle_completed ---

@test "handle_completed is a no-op that succeeds" {
  write_state "$TEST_PROJECT_DIR" "status" "completed"

  run _handle_completed "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "handle_completed logs pipeline completed message" {
  _handle_completed "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Pipeline completed"* ]]
}

# --- _push_and_create_draft_pr retry logic ---

# Helper: create a mock that fails on the first call, succeeds on subsequent.
_mock_fail_first() {
  local counter_file="$1"
  local success_output="$2"
  echo "0" > "$counter_file"
  # Caller must define the function body using this file.
  # Pattern: read counter, increment, fail if 0, else echo success_output.
}

# Mock git rev-list to report commits ahead of base (used by draft PR tests).
_mock_commits_ahead() {
  detect_default_branch() { echo "main"; }
  git() {
    if [[ "$*" == *"rev-list"* ]]; then echo "1"; return 0; fi
    command git "$@"
  }
}

@test "draft PR: retries create_draft_pr on first failure, succeeds on second" {
  local create_counter="$BATS_TEST_TMPDIR/create_attempt"
  local detect_counter="$BATS_TEST_TMPDIR/detect_calls"
  echo "0" > "$create_counter"
  echo "0" > "$detect_counter"
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() { return 0; }
  detect_task_pr() {
    local d; d="$(cat "$detect_counter")"
    echo "$(( d + 1 ))" > "$detect_counter"
    return 1
  }
  create_draft_pr() {
    local a; a="$(cat "$create_counter")"
    echo "$(( a + 1 ))" > "$create_counter"
    if [[ "$a" -eq 0 ]]; then return 1; fi
    echo "https://github.com/testowner/testrepo/pull/77"
  }
  sleep() { :; }

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "5"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ "$pr_number" = "77" ]

  local draft
  draft="$(read_state "$TEST_PROJECT_DIR" "draft_pr_number")"
  [ "$draft" = "77" ]

  # detect_task_pr should be called on both attempts (guards against duplicate PRs).
  local detect_calls
  detect_calls="$(cat "$detect_counter")"
  [ "$detect_calls" = "2" ]
}

@test "draft PR: pr_number is empty after all retries fail" {
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() { return 0; }
  detect_task_pr() { return 1; }
  create_draft_pr() { return 1; }
  sleep() { :; }

  # Set a stale pr_number to verify it gets cleared.
  write_state "$TEST_PROJECT_DIR" "pr_number" "999"

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "5"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ -z "$pr_number" ]
}

@test "draft PR: retries push once on failure" {
  local push_counter="$BATS_TEST_TMPDIR/push_attempt"
  echo "0" > "$push_counter"
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() {
    local a; a="$(cat "$push_counter")"
    echo "$(( a + 1 ))" > "$push_counter"
    if [[ "$a" -eq 0 ]]; then return 1; fi
    return 0
  }
  detect_task_pr() { return 1; }
  create_draft_pr() {
    echo "https://github.com/testowner/testrepo/pull/88"
  }
  sleep() { :; }

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "3"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ "$pr_number" = "88" ]
}

@test "draft PR: pr_number is empty when push retries exhausted" {
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() { return 1; }
  sleep() { :; }

  write_state "$TEST_PROJECT_DIR" "pr_number" "111"

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "3"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ -z "$pr_number" ]
}

@test "draft PR: succeeds on first attempt without retry" {
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() { return 0; }
  detect_task_pr() { return 1; }
  create_draft_pr() {
    echo "https://github.com/testowner/testrepo/pull/50"
  }
  sleep() { :; }

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "1"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ "$pr_number" = "50" ]
}

@test "draft PR: skipped when branch has no commits ahead of base" {
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  detect_default_branch() { echo "main"; }
  git() {
    # Simulate rev-list --count returning 0.
    if [[ "$*" == *"rev-list"* ]]; then echo "0"; return 0; fi
    command git "$@"
  }
  push_branch() { echo "SHOULD NOT BE CALLED" >&2; return 1; }
  create_draft_pr() { echo "SHOULD NOT BE CALLED" >&2; return 1; }

  run _push_and_create_draft_pr "$TEST_PROJECT_DIR" "5"

  [ "$status" -eq 0 ]
  # push_branch and create_draft_pr should not have been called — no state change.
  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")" || true
  [ -z "$pr_number" ]
}

@test "draft PR: proceeds when branch has commits ahead of base" {
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  detect_default_branch() { echo "main"; }
  git() {
    # Simulate rev-list --count returning 2 commits ahead.
    if [[ "$*" == *"rev-list"* ]]; then echo "2"; return 0; fi
    command git "$@"
  }
  push_branch() { return 0; }
  detect_task_pr() { return 1; }
  create_draft_pr() {
    echo "https://github.com/testowner/testrepo/pull/77"
  }
  sleep() { :; }

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "5"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ "$pr_number" = "77" ]
}

@test "draft PR: retry detects PR created by failed first attempt" {
  # Simulates: first create_draft_pr succeeds on GitHub but returns empty URL,
  # retry's detect_task_pr finds the PR that was actually created.
  resolve_task_dir() { echo "$TEST_PROJECT_DIR"; }
  _mock_commits_ahead
  push_branch() { return 0; }
  local detect_counter="$BATS_TEST_TMPDIR/detect_calls"
  echo "0" > "$detect_counter"
  detect_task_pr() {
    local d; d="$(cat "$detect_counter")"
    echo "$(( d + 1 ))" > "$detect_counter"
    # First call: no PR yet. Second call: PR was created by first attempt.
    if [[ "$d" -eq 0 ]]; then return 1; fi
    echo "https://github.com/testowner/testrepo/pull/99"
  }
  create_draft_pr() {
    # Always returns empty (simulates garbled response).
    echo ""
  }
  sleep() { :; }

  _push_and_create_draft_pr "$TEST_PROJECT_DIR" "7"

  local pr_number
  pr_number="$(read_state "$TEST_PROJECT_DIR" "pr_number")"
  [ "$pr_number" = "99" ]
}
