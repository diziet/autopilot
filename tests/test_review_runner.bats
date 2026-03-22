#!/usr/bin/env bats
# Tests for reviewer exponential backoff behavior.
# Covers: cooldown computation, phase transitions, failure tracking,
# success reset, and no PAUSE file creation.

BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/review_entry_setup

# --- Cooldown Computation (unit tests on _compute_reviewer_cooldown) ---

@test "first failure cooldown is 30s" {
  local result
  result=$(_compute_reviewer_cooldown 1)
  [ "$result" = "30" ]
}

@test "successive Phase 1 cooldowns: 30s, 60s, 120s, 240s" {
  [ "$(_compute_reviewer_cooldown 1)" = "30" ]
  [ "$(_compute_reviewer_cooldown 2)" = "60" ]
  [ "$(_compute_reviewer_cooldown 3)" = "120" ]
  [ "$(_compute_reviewer_cooldown 4)" = "240" ]
}

@test "Phase 2 cooldowns: 5m, 10m, 15m, 20m (linear +5m)" {
  [ "$(_compute_reviewer_cooldown 5)" = "300" ]
  [ "$(_compute_reviewer_cooldown 6)" = "600" ]
  [ "$(_compute_reviewer_cooldown 7)" = "900" ]
  [ "$(_compute_reviewer_cooldown 8)" = "1200" ]
}

@test "Phase 2 continues indefinitely with no cap" {
  # Step 20 = Phase 2 step 16 = 16*300 = 4800s.
  [ "$(_compute_reviewer_cooldown 20)" = "4800" ]
  # Step 100 = Phase 2 step 96 = 96*300 = 28800s (8 hours).
  [ "$(_compute_reviewer_cooldown 100)" = "28800" ]
}

# --- Failure Tracking Integration ---

@test "_track_reviewer_failure sets a cooldown in the future" {
  _track_reviewer_failure "$TEST_PROJECT_DIR"

  local cooldown_until
  cooldown_until="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"
  local now
  now="$(date +%s)"
  [ "$cooldown_until" -gt "$now" ]
}

@test "reviewer cron skips during cooldown without incrementing retry count" {
  write_state "$TEST_PROJECT_DIR" "status" "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Set cooldown in the future.
  local future
  future="$(( $(date +%s) + 300 ))"
  set_reviewer_cooldown_until "$TEST_PROJECT_DIR" "$future"
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 2

  local rc=0
  _run_cron_review "$TEST_PROJECT_DIR" || rc=$?
  [ "$rc" -eq "$REVIEW_ERROR" ]

  # Retry count should NOT have increased.
  local count
  count="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$count" = "2" ]
}

@test "successful review resets cooldown and retry count" {
  write_state "$TEST_PROJECT_DIR" "status" "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Pre-set some retries and a past cooldown (so review can proceed).
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3
  local past
  past="$(( $(date +%s) - 10 ))"
  set_reviewer_cooldown_until "$TEST_PROJECT_DIR" "$past"

  _run_cron_review "$TEST_PROJECT_DIR" || true

  local count
  count="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$count" = "0" ]

  local cooldown
  cooldown="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"
  [ "$cooldown" = "0" ]
}

@test "reviewer failures never create a PAUSE file" {
  local i
  for i in $(seq 1 10); do
    _track_reviewer_failure "$TEST_PROJECT_DIR"
  done

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

@test "Phase 1 to Phase 2 boundary logs CRITICAL" {
  # Phase 1 has 4 entries. 5th failure enters Phase 2.
  local i
  for i in $(seq 1 5); do
    _track_reviewer_failure "$TEST_PROJECT_DIR"
  done

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[CRITICAL]"* ]]
  [[ "$log_content" == *"Phase 1 retries exhausted"* ]]
  [[ "$log_content" == *"Phase 2"* ]]
}
