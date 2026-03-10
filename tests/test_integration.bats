#!/usr/bin/env bats
# Integration tests for cross-module interactions in Autopilot.
# Tests config→state→lock lifecycle, concurrent safety, state machine paths,
# crash recovery, config/task parsing edge cases, log rotation, metrics,
# reviewer dedup, and background test gate isolation.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/state.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/tasks.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/metrics.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/reviewer.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/reviewer-posting.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/testgate.sh"

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT_DIR"

  # Unset all AUTOPILOT_* env vars for clean slate.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)
}

# ===================================================================
# Config → State → Lock lifecycle
# ===================================================================

@test "integration: load config, init pipeline, acquire/release lock, verify state" {
  # Create a custom config with non-default values.
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=3
AUTOPILOT_STALE_LOCK_MINUTES=10
AUTOPILOT_MAX_LOG_LINES=50
CONF

  # Load config and verify values were set from file.
  load_config "$TEST_PROJECT_DIR"
  [ "$AUTOPILOT_MAX_RETRIES" = "3" ]
  [ "$AUTOPILOT_STALE_LOCK_MINUTES" = "10" ]
  [ "$AUTOPILOT_MAX_LOG_LINES" = "50" ]

  # Init pipeline — creates directory tree and state.json.
  init_pipeline "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/state.json" ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/locks" ]

  # Verify initial state.
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "pending" ]

  # Acquire lock, verify PID.
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]

  # Increment retry, verify it respects config max.
  increment_retry "$TEST_PROJECT_DIR"
  local count
  count="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$count" = "1" ]

  # State transitions should work.
  update_status "$TEST_PROJECT_DIR" "implementing"
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "implementing" ]

  # Release lock.
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

@test "integration: config file values respected in stale lock detection" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_STALE_LOCK_MINUTES=0
CONF
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Create lock with PID 1 (init, always alive).
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  # With STALE_LOCK_MINUTES=0 from config, any lock is immediately stale.
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]
}

@test "integration: retry count resets correctly across task advance" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Increment retry 3 times.
  increment_retry "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "3" ]

  # Reset (simulates task advance).
  reset_retry "$TEST_PROJECT_DIR"
  [ "$(get_retry_count "$TEST_PROJECT_DIR")" = "0" ]

  # Test fix retries work independently.
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "2" ]
  reset_test_fix_retries "$TEST_PROJECT_DIR"
  [ "$(get_test_fix_retries "$TEST_PROJECT_DIR")" = "0" ]
}

# ===================================================================
# Concurrent dispatcher safety
# ===================================================================

@test "integration: re-entrant lock acquire fails when already held" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Acquire lock.
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"

  # Second acquire from the same process should fail — noclobber prevents
  # overwriting the lock file, and our own PID is alive (not stale).
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]

  release_lock "$TEST_PROJECT_DIR" "pipeline"
}

@test "integration: stale lock from dead PID gets stolen" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Write a lock with a PID that doesn't exist.
  echo "99999999" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  # New process should detect dead PID and steal the lock.
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]

  # Verify our PID is now in the lock file.
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]

  # Log should contain stale lock warning.
  grep -q "stale lock" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "integration: lock with empty PID treated as stale" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Empty lock file (corrupt/stale).
  echo "" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

# ===================================================================
# State machine full path
# ===================================================================

@test "integration: full state machine path pending through completed" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Verify we start in pending.
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "pending" ]

  # Walk through every state transition in the happy path.
  local -a transitions=(
    "implementing"
    "pr_open"
    "reviewed"
    "fixing"
    "fixed"
    "merging"
    "merged"
    "pending"
  )

  for next_status in "${transitions[@]}"; do
    update_status "$TEST_PROJECT_DIR" "$next_status"
    [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "$next_status" ]
  done

  # Now complete the pipeline.
  update_status "$TEST_PROJECT_DIR" "completed"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "completed" ]
}

@test "integration: state machine path with test_fixing detour" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"
  update_status "$TEST_PROJECT_DIR" "test_fixing"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "test_fixing" ]

  # test_fixing → pr_open (tests pass after fix).
  update_status "$TEST_PROJECT_DIR" "pr_open"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "pr_open" ]
}

@test "integration: reviewed to fixed skip (clean review path)" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"
  update_status "$TEST_PROJECT_DIR" "pr_open"
  update_status "$TEST_PROJECT_DIR" "reviewed"

  # Direct skip: reviewed → fixed (all reviews clean).
  update_status "$TEST_PROJECT_DIR" "fixed"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "fixed" ]
}

@test "integration: merging rejection loops back to reviewed" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"
  update_status "$TEST_PROJECT_DIR" "pr_open"
  update_status "$TEST_PROJECT_DIR" "reviewed"
  update_status "$TEST_PROJECT_DIR" "fixing"
  update_status "$TEST_PROJECT_DIR" "fixed"
  update_status "$TEST_PROJECT_DIR" "merging"

  # Rejection: merging → reviewed.
  update_status "$TEST_PROJECT_DIR" "reviewed"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "reviewed" ]
}

@test "integration: invalid transition rejected" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # pending → fixed is not valid.
  run update_status "$TEST_PROJECT_DIR" "fixed"
  [ "$status" -eq 1 ]

  # State should remain pending.
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "pending" ]
}

@test "integration: state json correct at each step with counters" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Set up task number and counters.
  write_state_num "$TEST_PROJECT_DIR" "current_task" 5
  increment_retry "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"

  # Verify all fields in state.json are correct.
  local task_num status_val retry_val
  task_num="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  status_val="$(read_state "$TEST_PROJECT_DIR" "status")"
  retry_val="$(read_state "$TEST_PROJECT_DIR" "retry_count")"

  [ "$task_num" = "5" ]
  [ "$status_val" = "implementing" ]
  [ "$retry_val" = "1" ]
}

# ===================================================================
# Crash recovery
# ===================================================================

@test "integration: corrupt state.json recoverable via manual reset" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"

  # Simulate crash: corrupt state.json with partial write.
  echo '{"status":"implem' > "$TEST_PROJECT_DIR/.autopilot/state.json"

  # read_state should fail gracefully (jq parse error returns empty).
  local result
  result="$(read_state "$TEST_PROJECT_DIR" "status" 2>/dev/null || true)"
  [ -z "$result" ]

  # Recovery: write a fresh valid state.json directly.
  echo '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}' \
    > "$TEST_PROJECT_DIR/.autopilot/state.json"

  result="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$result" = "pending" ]
}

@test "integration: orphan lock file cleaned up on next acquire" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Simulate crash: lock file left behind with a dead PID.
  echo "99999999" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  # Next dispatcher tick acquires the lock, cleaning up the orphan.
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]

  release_lock "$TEST_PROJECT_DIR" "pipeline"
}

@test "integration: stuck merging state recoverable" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  update_status "$TEST_PROJECT_DIR" "implementing"
  update_status "$TEST_PROJECT_DIR" "pr_open"
  update_status "$TEST_PROJECT_DIR" "reviewed"
  update_status "$TEST_PROJECT_DIR" "fixing"
  update_status "$TEST_PROJECT_DIR" "fixed"
  update_status "$TEST_PROJECT_DIR" "merging"

  # Simulate crash during merge: state stuck in merging.
  # Recovery: transition back to reviewed.
  update_status "$TEST_PROJECT_DIR" "reviewed"
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "reviewed" ]
}

# ===================================================================
# Config edge cases
# ===================================================================

@test "integration: malformed config lines ignored safely" {
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
# This is a comment
AUTOPILOT_MAX_RETRIES=7

INVALID_LINE_NO_PREFIX=123
=missing_key
AUTOPILOT_UNKNOWN_VAR=should_be_ignored
  AUTOPILOT_MAX_LOG_LINES = 500
AUTOPILOT_TIMEOUT_CODER=1800
CONF

  load_config "$TEST_PROJECT_DIR"

  # Valid line should be parsed.
  [ "$AUTOPILOT_MAX_RETRIES" = "7" ]
  [ "$AUTOPILOT_TIMEOUT_CODER" = "1800" ]

  # Default should remain for unparseable lines.
  [ "$AUTOPILOT_MAX_LOG_LINES" = "50000" ]
}

@test "integration: empty values in config file override non-empty defaults" {
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=
AUTOPILOT_TARGET_BRANCH=
CONF

  load_config "$TEST_PROJECT_DIR"

  # Default for BRANCH_PREFIX is "autopilot" — verify config file overrode to empty.
  [ "$AUTOPILOT_BRANCH_PREFIX" = "" ]
  [ "$AUTOPILOT_TARGET_BRANCH" = "" ]
}

@test "integration: duplicate keys — last value wins" {
  mkdir -p "$TEST_PROJECT_DIR"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=3
AUTOPILOT_MAX_RETRIES=9
CONF

  load_config "$TEST_PROJECT_DIR"
  [ "$AUTOPILOT_MAX_RETRIES" = "9" ]
}

@test "integration: both config files with conflicting values" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=3
AUTOPILOT_TIMEOUT_CODER=1000
CONF

  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=10
CONF

  load_config "$TEST_PROJECT_DIR"

  # .autopilot/config.conf overrides autopilot.conf.
  [ "$AUTOPILOT_MAX_RETRIES" = "10" ]
  # autopilot.conf value kept where not overridden.
  [ "$AUTOPILOT_TIMEOUT_CODER" = "1000" ]
}

@test "integration: env var overrides both config files" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=3
CONF
  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=10
CONF

  export AUTOPILOT_MAX_RETRIES=99
  load_config "$TEST_PROJECT_DIR"

  [ "$AUTOPILOT_MAX_RETRIES" = "99" ]
  unset AUTOPILOT_MAX_RETRIES
}

# ===================================================================
# Task parsing edge cases
# ===================================================================

@test "integration: empty tasks file returns count 0" {
  mkdir -p "$TEST_PROJECT_DIR"
  touch "$TEST_PROJECT_DIR/tasks.md"

  run count_tasks "$TEST_PROJECT_DIR/tasks.md"
  [ "$output" = "0" ]
}

@test "integration: tasks file with only comments" {
  cat > "$TEST_PROJECT_DIR/tasks.md" <<'EOF'
# Project Tasks

This file has comments but no task headings.

Some other markdown content.
EOF

  run count_tasks "$TEST_PROJECT_DIR/tasks.md"
  [ "$output" = "0" ]
}

@test "integration: task numbers with gaps" {
  cat > "$TEST_PROJECT_DIR/tasks.md" <<'EOF'
## Task 1
First task body.

## Task 5
Fifth task body (gaps in numbering).

## Task 10
Tenth task body.
EOF

  run count_tasks "$TEST_PROJECT_DIR/tasks.md"
  [ "$output" = "3" ]

  # Can extract each task by number even with gaps.
  run extract_task "$TEST_PROJECT_DIR/tasks.md" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fifth task body"* ]]

  run extract_task "$TEST_PROJECT_DIR/tasks.md" 2
  [ "$status" -eq 1 ]
}

@test "integration: mixed Task N and PR N formats in same file" {
  cat > "$TEST_PROJECT_DIR/tasks.md" <<'EOF'
## Task 1
First task.

### PR 2
Second PR.

## Task 3
Third task.
EOF

  # _detect_task_format uses first match. Task N format found first.
  run count_tasks "$TEST_PROJECT_DIR/tasks.md"
  [ "$output" = "2" ]

  # Should extract Task format headings.
  run extract_task "$TEST_PROJECT_DIR/tasks.md" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"First task"* ]]
}

# ===================================================================
# Lock file races
# ===================================================================

@test "integration: acquire lock verifies PID written correctly" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  acquire_lock "$TEST_PROJECT_DIR" "pipeline"

  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]

  # Simulate stale lock: write dead PID manually.
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  echo "88888888" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  # Next acquire should detect dead PID and steal.
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]

  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]
}

@test "integration: multiple lock names don't interfere" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  acquire_lock "$TEST_PROJECT_DIR" "reviewer"

  # Both should exist.
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/reviewer.lock" ]

  # Release one, the other stays.
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/reviewer.lock" ]

  release_lock "$TEST_PROJECT_DIR" "reviewer"
}

# ===================================================================
# Log rotation
# ===================================================================

@test "integration: log rotation truncates correctly keeping recent entries" {
  AUTOPILOT_MAX_LOG_LINES=20
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Write more than MAX_LOG_LINES entries.
  local i
  for i in $(seq 1 25); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "Log entry number $i"
  done

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  [ -f "$log_file" ]

  # Rotation is throttled in log_msg — trigger it explicitly.
  _rotate_log "$log_file"

  local line_count
  line_count="$(wc -l < "$log_file" | tr -d ' ')"

  # After rotation: should be <= MAX_LOG_LINES (rotation keeps half = 10).
  [ "$line_count" -le 20 ]

  # Most recent entries should still be present (anchored to avoid substring match).
  grep -q "Log entry number 25$" "$log_file"
  grep -q "Log entry number 24$" "$log_file"

  # Earliest entries should have been rotated away.
  # Use $ anchor: "number 1" would match "number 10", "number 12", etc.
  ! grep -q "Log entry number 1$" "$log_file"
  ! grep -q "Log entry number 5$" "$log_file"
}

# ===================================================================
# Metrics integrity
# ===================================================================

@test "integration: metrics CSV has correct columns and non-negative values" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Override get_pr_stats directly to avoid real GitHub API calls.
  # (export -f gh doesn't work because timeout uses execvp, not bash.)
  get_pr_stats() {
    echo '{"additions":10,"deletions":5,"changed_files":3,"comment_count":2}'
  }

  # Record task start.
  record_task_start "$TEST_PROJECT_DIR" 1

  # Simulate phases with transitions.
  update_status "$TEST_PROJECT_DIR" "implementing"
  record_phase_transition "$TEST_PROJECT_DIR" "pending"

  update_status "$TEST_PROJECT_DIR" "pr_open"
  record_phase_transition "$TEST_PROJECT_DIR" "implementing"

  update_status "$TEST_PROJECT_DIR" "reviewed"
  record_phase_transition "$TEST_PROJECT_DIR" "pr_open"

  update_status "$TEST_PROJECT_DIR" "fixed"
  record_phase_transition "$TEST_PROJECT_DIR" "reviewed"

  update_status "$TEST_PROJECT_DIR" "merging"
  record_phase_transition "$TEST_PROJECT_DIR" "fixed"

  update_status "$TEST_PROJECT_DIR" "merged"
  record_phase_transition "$TEST_PROJECT_DIR" "merging"

  # Record task completion.
  record_task_complete "$TEST_PROJECT_DIR" 1 42 "owner/repo"

  local metrics_file="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  [ -f "$metrics_file" ]

  # Verify header.
  local header
  header="$(head -1 "$metrics_file")"
  [[ "$header" == *"task_number"* ]]
  [[ "$header" == *"duration_minutes"* ]]

  # Verify data row exists with correct stat values from mock.
  local data_line
  data_line="$(tail -1 "$metrics_file")"
  [[ "$data_line" == "1,"* ]]
  [[ "$data_line" == *",10,5,2,3" ]]

  # Record phase durations.
  record_phase_durations "$TEST_PROJECT_DIR" 1 42

  local phase_file="$TEST_PROJECT_DIR/.autopilot/phase_timing.csv"
  [ -f "$phase_file" ]

  # Verify phase header.
  local phase_header
  phase_header="$(head -1 "$phase_file")"
  [[ "$phase_header" == *"implementing_sec"* ]]
  [[ "$phase_header" == *"total_sec"* ]]

  # Verify data row — all timing values should be non-negative.
  local phase_data
  phase_data="$(tail -1 "$phase_file")"
  [[ "$phase_data" == "1,"* ]]

  # Check no negative values in the phase data.
  local field
  while IFS=',' read -ra fields; do
    for field in "${fields[@]}"; do
      if [[ "$field" =~ ^-[0-9] ]]; then
        echo "Found negative value: $field"
        return 1
      fi
    done
  done <<< "$phase_data"
}

@test "integration: metrics deduplication prevents double recording" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Override get_pr_stats to avoid real GitHub API calls.
  get_pr_stats() {
    echo '{"additions":0,"deletions":0,"changed_files":0,"comment_count":0}'
  }

  record_task_start "$TEST_PROJECT_DIR" 1
  record_task_complete "$TEST_PROJECT_DIR" 1 42 "owner/repo"
  record_task_complete "$TEST_PROJECT_DIR" 1 42 "owner/repo"

  local metrics_file="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  local data_count
  data_count="$(tail -n +2 "$metrics_file" | wc -l | tr -d ' ')"
  [ "$data_count" = "1" ]
}

# ===================================================================
# Reviewer dedup
# ===================================================================

@test "integration: reviewed SHA tracked and dedup prevents duplicate" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  local sha="abc1234567890"
  local pr_num=42

  # First review: not yet reviewed.
  run has_been_reviewed "$TEST_PROJECT_DIR" "$pr_num" "general" "$sha"
  [ "$status" -eq 1 ]

  # Record review.
  set_reviewed_sha "$TEST_PROJECT_DIR" "$pr_num" "general" "$sha" "false"

  # Now should be marked as reviewed.
  run has_been_reviewed "$TEST_PROJECT_DIR" "$pr_num" "general" "$sha"
  [ "$status" -eq 0 ]

  # Different SHA should not be considered reviewed.
  run has_been_reviewed "$TEST_PROJECT_DIR" "$pr_num" "general" "different_sha"
  [ "$status" -eq 1 ]
}

@test "integration: multiple personas tracked independently" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  local sha="abc123" pr_num=10

  set_reviewed_sha "$TEST_PROJECT_DIR" "$pr_num" "general" "$sha" "true"
  set_reviewed_sha "$TEST_PROJECT_DIR" "$pr_num" "security" "$sha" "false"

  run was_review_clean "$TEST_PROJECT_DIR" "$pr_num" "general"
  [ "$status" -eq 0 ]

  run was_review_clean "$TEST_PROJECT_DIR" "$pr_num" "security"
  [ "$status" -eq 1 ]
}

# ===================================================================
# Clean-review skip
# ===================================================================

@test "integration: all clean reviews detected via result files" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Create mock review result directory with all-clean responses.
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Mock extract_claude_text to return NO_ISSUES_FOUND.
  local output_file_1="$result_dir/general_output.json"
  local output_file_2="$result_dir/dry_output.json"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$output_file_1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$output_file_2"

  # Write meta files.
  printf '%s\n%s\n' "$output_file_1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$output_file_2" "0" > "$result_dir/dry.meta"

  # all_reviews_clean should return true.
  run all_reviews_clean "$result_dir"
  [ "$status" -eq 0 ]
}

@test "integration: mixed clean and issue reviews not counted as all-clean" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local output_file_1="$result_dir/general_output.json"
  local output_file_2="$result_dir/security_output.json"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$output_file_1"
  echo '{"result":"Found SQL injection vulnerability in auth.py"}' > "$output_file_2"

  printf '%s\n%s\n' "$output_file_1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$output_file_2" "0" > "$result_dir/security.meta"

  run all_reviews_clean "$result_dir"
  [ "$status" -eq 1 ]
}

# ===================================================================
# Background test gate
# ===================================================================

@test "integration: test gate SHA flag prevents redundant runs" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Write a SHA flag (simulating hooks verified tests already).
  local fake_sha="deadbeef1234567890"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$fake_sha"

  # Verify the flag was written.
  local stored_sha
  stored_sha="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ "$stored_sha" = "$fake_sha" ]

  # Clear and verify it's gone.
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  stored_sha="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ -z "$stored_sha" ]
}

@test "integration: test gate detects test framework" {
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Create a Makefile with test target.
  cat > "$TEST_PROJECT_DIR/Makefile" <<'EOF'
test:
	echo "running tests"
EOF

  local cmd
  cmd="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$cmd" = "make test" ]
}

@test "integration: custom test command bypasses allowlist in resolve" {
  AUTOPILOT_TEST_CMD="./run-my-tests.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  # Clear any SHA flag so _resolve_test_cmd doesn't short-circuit.
  clear_hook_sha_flag "$TEST_PROJECT_DIR"

  # _resolve_test_cmd enforces the allowlist for auto-detected commands
  # but should bypass it for custom AUTOPILOT_TEST_CMD. "./run-my-tests.sh"
  # is not on the allowlist (pytest, npm, bats, make), so this verifies bypass.
  run _resolve_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "./run-my-tests.sh" ]
}
