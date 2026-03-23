#!/usr/bin/env bats
# Tests for reviewer exponential backoff in lib/review-runner.sh.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/review_entry_setup

# --- First failure sets a short cooldown ---

@test "first reviewer failure sets a 15s cooldown" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"

  # Retry count starts at 0.
  reset_reviewer_retries "$TEST_PROJECT_DIR"
  clear_reviewer_cooldown "$TEST_PROJECT_DIR"

  local before
  before="$(date +%s)"
  _track_reviewer_failure "$TEST_PROJECT_DIR"

  local cooldown_until
  cooldown_until="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"

  # Cooldown should be ~15s from before (allow ±5s for test execution).
  local diff=$(( cooldown_until - before ))
  [ "$diff" -ge 13 ]
  [ "$diff" -le 20 ]
}

# --- Successive failures increase cooldown exponentially ---

@test "successive failures increase cooldown: 15s, 30s, 60s, 120s, 240s" {
  _set_state "pr_open"
  reset_reviewer_retries "$TEST_PROJECT_DIR"
  clear_reviewer_cooldown "$TEST_PROJECT_DIR"

  # Verify via _compute_reviewer_cooldown (no timing issues).
  [ "$(_compute_reviewer_cooldown 0)" -eq 15 ]
  [ "$(_compute_reviewer_cooldown 1)" -eq 30 ]
  [ "$(_compute_reviewer_cooldown 2)" -eq 60 ]
  [ "$(_compute_reviewer_cooldown 3)" -eq 120 ]
  [ "$(_compute_reviewer_cooldown 4)" -eq 240 ]

  # Also verify that actual failures store increasing cooldowns.
  local before
  before="$(date +%s)"
  _track_reviewer_failure "$TEST_PROJECT_DIR"
  local cooldown1
  cooldown1="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"
  _track_reviewer_failure "$TEST_PROJECT_DIR"
  local cooldown2
  cooldown2="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"

  # Second cooldown should be further in the future than first.
  [ "$cooldown2" -gt "$cooldown1" ]
}

# --- Reviewer cron skips during cooldown without incrementing retry count ---

@test "reviewer cron skips during cooldown without incrementing retries" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  reset_reviewer_retries "$TEST_PROJECT_DIR"

  # Set cooldown 60s in the future.
  local now
  now="$(date +%s)"
  set_reviewer_cooldown_until "$TEST_PROJECT_DIR" $(( now + 60 ))
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 2

  run _run_cron_review "$TEST_PROJECT_DIR"
  [ "$status" -eq "$REVIEW_ERROR" ]

  # Retry count should NOT have incremented.
  local retries
  retries="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 2 ]
}

# --- Successful review resets cooldown and retry count ---

@test "successful review resets cooldown and retry count" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  AUTOPILOT_REVIEWERS="general"

  # Set up some failures first.
  write_state_num "$TEST_PROJECT_DIR" "reviewer_retry_count" 3
  local now
  now="$(date +%s)"
  set_reviewer_cooldown_until "$TEST_PROJECT_DIR" $(( now - 10 ))

  _run_cron_review "$TEST_PROJECT_DIR"

  local retries
  retries="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 0 ]

  local cooldown
  cooldown="$(get_reviewer_cooldown_until "$TEST_PROJECT_DIR")"
  [ "$cooldown" -eq 0 ]
}

# --- Reviewer failures never create a PAUSE file ---

@test "reviewer failures never create a PAUSE file" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  reset_reviewer_retries "$TEST_PROJECT_DIR"
  clear_reviewer_cooldown "$TEST_PROJECT_DIR"

  # Simulate 10 consecutive failures.
  local i
  for i in $(seq 1 10); do
    _track_reviewer_failure "$TEST_PROJECT_DIR"
    # Clear cooldown so next failure can proceed.
    clear_reviewer_cooldown "$TEST_PROJECT_DIR"
  done

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

# --- Phase 1 → Phase 2 boundary logs CRITICAL ---

@test "phase 1 exhausted logs CRITICAL and enters phase 2" {
  _set_state "pr_open"
  reset_reviewer_retries "$TEST_PROJECT_DIR"
  clear_reviewer_cooldown "$TEST_PROJECT_DIR"

  # Exhaust Phase 1 (5 failures at indices 0-4).
  local i
  for i in $(seq 1 5); do
    _track_reviewer_failure "$TEST_PROJECT_DIR"
    clear_reviewer_cooldown "$TEST_PROJECT_DIR"
  done

  # The 6th failure (retry_count=5) should log CRITICAL.
  _track_reviewer_failure "$TEST_PROJECT_DIR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"CRITICAL"*"Phase 1 retries exhausted"* ]]
}

# --- Phase 2 retries at 5m, 10m, 15m, 20m, ... ---

@test "phase 2 cooldowns increase by 5m each time: 300s, 600s, 900s, 1200s" {
  # Verify via _compute_reviewer_cooldown (avoids timing issues).
  [ "$(_compute_reviewer_cooldown 5)" -eq 300 ]
  [ "$(_compute_reviewer_cooldown 6)" -eq 600 ]
  [ "$(_compute_reviewer_cooldown 7)" -eq 900 ]
  [ "$(_compute_reviewer_cooldown 8)" -eq 1200 ]
  [ "$(_compute_reviewer_cooldown 20)" -eq 4800 ]
}
