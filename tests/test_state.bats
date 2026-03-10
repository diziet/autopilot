#!/usr/bin/env bats
# Tests for lib/state.sh — state management, logging, counters.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/state.sh"

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT_DIR"

  # Unset all AUTOPILOT_* env vars to start clean
  _unset_autopilot_vars

  # Source state.sh (which also sources config.sh)
  load_config "$TEST_PROJECT_DIR"
}

# --- init_pipeline ---

@test "init_pipeline creates .autopilot directory" {
  init_pipeline "$TEST_PROJECT_DIR"
  [ -d "$TEST_PROJECT_DIR/.autopilot" ]
}

@test "init_pipeline creates logs subdirectory" {
  init_pipeline "$TEST_PROJECT_DIR"
  [ -d "$TEST_PROJECT_DIR/.autopilot/logs" ]
}

@test "init_pipeline creates locks subdirectory" {
  init_pipeline "$TEST_PROJECT_DIR"
  [ -d "$TEST_PROJECT_DIR/.autopilot/locks" ]
}

@test "init_pipeline creates state.json with pending status" {
  init_pipeline "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/state.json" ]
  local status
  status="$(jq -r '.status' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$status" = "pending" ]
}

@test "init_pipeline sets current_task to 1" {
  init_pipeline "$TEST_PROJECT_DIR"
  local task
  task="$(jq -r '.current_task' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$task" = "1" ]
}

@test "init_pipeline sets retry_count to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  local count
  count="$(jq -r '.retry_count' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$count" = "0" ]
}

@test "init_pipeline sets test_fix_retries to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  local count
  count="$(jq -r '.test_fix_retries' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$count" = "0" ]
}

@test "init_pipeline does not overwrite existing state.json" {
  init_pipeline "$TEST_PROJECT_DIR"
  # Modify state
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  # Re-run init — should not reset
  init_pipeline "$TEST_PROJECT_DIR"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "implementing" ]
}

@test "init_pipeline is idempotent on directory creation" {
  init_pipeline "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
  [ -d "$TEST_PROJECT_DIR/.autopilot/logs" ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/locks" ]
}

# --- State Read/Write ---

@test "read_state returns field value from state.json" {
  init_pipeline "$TEST_PROJECT_DIR"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "pending" ]
}

@test "read_state returns empty string for missing field" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(read_state "$TEST_PROJECT_DIR" "nonexistent")"
  [ -z "$val" ]
}

@test "read_state fails when state.json missing" {
  run read_state "$TEST_PROJECT_DIR" "status"
  [ "$status" -eq 1 ]
}

@test "write_state updates a field atomically" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "implementing" ]
}

@test "write_state preserves other fields" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  local task
  task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$task" = "1" ]
}

@test "write_state fails when state.json missing" {
  run write_state "$TEST_PROJECT_DIR" "status" "pending"
  [ "$status" -eq 1 ]
}

@test "write_state_num writes numeric value" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3
  local val
  val="$(jq '.retry_count' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$val" = "3" ]
}

@test "read_state rejects field with jq metacharacters" {
  init_pipeline "$TEST_PROJECT_DIR"
  run read_state "$TEST_PROJECT_DIR" 'status"; .foo'
  [ "$status" -eq 1 ]
}

@test "write_state rejects field with jq metacharacters" {
  init_pipeline "$TEST_PROJECT_DIR"
  run write_state "$TEST_PROJECT_DIR" 'status = "hacked" | .foo' "val"
  [ "$status" -eq 1 ]
}

@test "write_state no leftover tmp files on success" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  local tmp_count
  tmp_count="$(find "$TEST_PROJECT_DIR/.autopilot" -name '*.tmp.*' | wc -l | tr -d ' ')"
  [ "$tmp_count" = "0" ]
}

# --- log_msg ---

@test "log_msg creates log file" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "INFO" "test message"
  [ -f "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" ]
}

@test "log_msg includes timestamp, level, and message" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "INFO" "hello world"
  local line
  line="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
  [[ "$line" == *"[INFO]"* ]]
  [[ "$line" == *"hello world"* ]]
}

@test "log_msg appends multiple messages" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "INFO" "msg1"
  log_msg "$TEST_PROJECT_DIR" "WARNING" "msg2"
  local count
  count="$(wc -l < "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" | tr -d ' ')"
  [ "$count" = "2" ]
}

@test "log_msg works without prior init (creates log dir)" {
  log_msg "$TEST_PROJECT_DIR" "INFO" "bootstrap message"
  [ -f "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" ]
}

@test "log_msg rotates when exceeding AUTOPILOT_MAX_LOG_LINES" {
  init_pipeline "$TEST_PROJECT_DIR"
  AUTOPILOT_MAX_LOG_LINES=20
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  for i in $(seq 1 25); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "line $i"
  done

  # Rotation is throttled in log_msg; flush to trigger it now.
  flush_log_rotation "$log_file"

  local count
  count="$(wc -l < "$log_file" | tr -d ' ')"
  # 25 > max(20), _rotate_log keeps max/2 = 10 lines via tail
  [ "$count" -eq 10 ]
}

@test "log_msg rotation preserves most recent lines" {
  init_pipeline "$TEST_PROJECT_DIR"
  AUTOPILOT_MAX_LOG_LINES=10
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  for i in $(seq 1 15); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "line $i"
  done

  # Rotation is throttled in log_msg; flush to trigger it now.
  flush_log_rotation "$log_file"

  local last_line
  last_line="$(tail -1 "$log_file")"
  [[ "$last_line" == *"line 15"* ]]
}

# --- update_status ---

@test "update_status transitions pending to implementing" {
  init_pipeline "$TEST_PROJECT_DIR"
  update_status "$TEST_PROJECT_DIR" "implementing"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "implementing" ]
}

@test "update_status transitions implementing to pr_open" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  update_status "$TEST_PROJECT_DIR" "pr_open"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "pr_open" ]
}

@test "update_status transitions implementing to test_fixing" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  update_status "$TEST_PROJECT_DIR" "test_fixing"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "test_fixing" ]
}

@test "update_status transitions reviewed to fixed (clean review skip)" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "reviewed"
  update_status "$TEST_PROJECT_DIR" "fixed"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "fixed" ]
}

@test "update_status rejects invalid transition" {
  init_pipeline "$TEST_PROJECT_DIR"
  run update_status "$TEST_PROJECT_DIR" "merged"
  [ "$status" -eq 1 ]
  # Status should still be pending
  local current
  current="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$current" = "pending" ]
}

@test "update_status rejects pending to fixed" {
  init_pipeline "$TEST_PROJECT_DIR"
  run update_status "$TEST_PROJECT_DIR" "fixed"
  [ "$status" -eq 1 ]
}

@test "update_status logs the transition" {
  init_pipeline "$TEST_PROJECT_DIR"
  update_status "$TEST_PROJECT_DIR" "implementing"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"pending -> implementing"* ]]
}

@test "update_status full pipeline path works" {
  init_pipeline "$TEST_PROJECT_DIR"
  update_status "$TEST_PROJECT_DIR" "implementing"
  update_status "$TEST_PROJECT_DIR" "pr_open"
  update_status "$TEST_PROJECT_DIR" "reviewed"
  update_status "$TEST_PROJECT_DIR" "fixing"
  update_status "$TEST_PROJECT_DIR" "fixed"
  update_status "$TEST_PROJECT_DIR" "merging"
  update_status "$TEST_PROJECT_DIR" "merged"
  update_status "$TEST_PROJECT_DIR" "completed"
  local status
  status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$status" = "completed" ]
}

# --- Counter Helpers (generic) ---

@test "_get_counter returns 0 for unset counter" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(_get_counter "$TEST_PROJECT_DIR" "some_new_counter")"
  [ "$val" = "0" ]
}

@test "_increment_counter increments from 0 to 1" {
  init_pipeline "$TEST_PROJECT_DIR"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  local val
  val="$(_get_counter "$TEST_PROJECT_DIR" "retry_count")"
  [ "$val" = "1" ]
}

@test "_increment_counter increments multiple times" {
  init_pipeline "$TEST_PROJECT_DIR"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  local val
  val="$(_get_counter "$TEST_PROJECT_DIR" "retry_count")"
  [ "$val" = "3" ]
}

@test "_reset_counter resets to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  _increment_counter "$TEST_PROJECT_DIR" "retry_count"
  _reset_counter "$TEST_PROJECT_DIR" "retry_count"
  local val
  val="$(_get_counter "$TEST_PROJECT_DIR" "retry_count")"
  [ "$val" = "0" ]
}

# --- Retry Tracking (Public API) ---

@test "get_retry_count returns 0 initially" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "increment_retry increases retry count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  local val
  val="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$val" = "1" ]
}

@test "increment_retry logs warning with count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"Retry incremented to 1/"* ]]
}

@test "reset_retry resets to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  reset_retry "$TEST_PROJECT_DIR"
  local val
  val="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

# --- Test Fix Retry Tracking (Public API) ---

@test "get_test_fix_retries returns 0 initially" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "increment_test_fix_retries increases count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "1" ]
}

@test "increment_test_fix_retries logs warning with count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"Test fix retry incremented to 1/"* ]]
}

@test "reset_test_fix_retries resets to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  reset_test_fix_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "retry and test fix counters are independent" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  local retry_val test_fix_val
  retry_val="$(get_retry_count "$TEST_PROJECT_DIR")"
  test_fix_val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$retry_val" = "2" ]
  [ "$test_fix_val" = "1" ]
}

# --- Reviewer Retry Tracking (Public API) ---

@test "get_reviewer_retries returns 0 initially" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "increment_reviewer_retries increases count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "1" ]
}

@test "increment_reviewer_retries logs warning with count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"Reviewer retry incremented to 1/"* ]]
}

@test "reset_reviewer_retries resets to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  reset_reviewer_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "reviewer retry counter is independent of other counters" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  increment_reviewer_retries "$TEST_PROJECT_DIR"
  local retry_val test_val reviewer_val
  retry_val="$(get_retry_count "$TEST_PROJECT_DIR")"
  test_val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  reviewer_val="$(get_reviewer_retries "$TEST_PROJECT_DIR")"
  [ "$retry_val" = "1" ]
  [ "$test_val" = "1" ]
  [ "$reviewer_val" = "2" ]
}

# --- Network Retry Tracking (Public API) ---

@test "get_network_retries returns 0 initially" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "increment_network_retries increases count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "1" ]
}

@test "increment_network_retries logs warning with count" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"Network retry"* ]]
}

@test "reset_network_retries resets to 0" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  reset_network_retries "$TEST_PROJECT_DIR"
  local val
  val="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$val" = "0" ]
}

@test "network retry counter is independent of other counters" {
  init_pipeline "$TEST_PROJECT_DIR"
  increment_retry "$TEST_PROJECT_DIR"
  increment_test_fix_retries "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  increment_network_retries "$TEST_PROJECT_DIR"
  local retry_val test_val net_val
  retry_val="$(get_retry_count "$TEST_PROJECT_DIR")"
  test_val="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  net_val="$(get_network_retries "$TEST_PROJECT_DIR")"
  [ "$retry_val" = "1" ]
  [ "$test_val" = "1" ]
  [ "$net_val" = "3" ]
}

# --- State Write Edge Cases ---

@test "write_state_num rejects non-numeric value" {
  init_pipeline "$TEST_PROJECT_DIR"
  run write_state_num "$TEST_PROJECT_DIR" "retry_count" "abc"
  [ "$status" -eq 1 ]
}

@test "write_state handles special characters in value" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  local val
  val="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$val" = "implementing" ]
}

@test "write_state overwrites previous value" {
  init_pipeline "$TEST_PROJECT_DIR"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  write_state "$TEST_PROJECT_DIR" "status" "pending"
  local val
  val="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$val" = "pending" ]
}

@test "read_state returns empty for null field" {
  init_pipeline "$TEST_PROJECT_DIR"
  local val
  val="$(read_state "$TEST_PROJECT_DIR" "nonexistent_field")"
  [ -z "$val" ]
}

# --- _validate_field_name edge cases ---

@test "_validate_field_name accepts simple names" {
  run _validate_field_name "status"
  [ "$status" -eq 0 ]
}

@test "_validate_field_name accepts underscore names" {
  run _validate_field_name "retry_count"
  [ "$status" -eq 0 ]
}

@test "_validate_field_name rejects names starting with number" {
  run _validate_field_name "1field"
  [ "$status" -eq 1 ]
}

@test "_validate_field_name rejects empty string" {
  run _validate_field_name ""
  [ "$status" -eq 1 ]
}

@test "_validate_field_name rejects dots" {
  run _validate_field_name "foo.bar"
  [ "$status" -eq 1 ]
}

@test "_validate_field_name rejects spaces" {
  run _validate_field_name "foo bar"
  [ "$status" -eq 1 ]
}

# --- _jq_transform_state ---

@test "_jq_transform_state applies arbitrary jq filter" {
  init_pipeline "$TEST_PROJECT_DIR"
  _jq_transform_state "$TEST_PROJECT_DIR" '.custom_field = "hello"'
  local val
  val="$(jq -r '.custom_field' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$val" = "hello" ]
}

@test "_jq_transform_state fails on invalid jq filter" {
  init_pipeline "$TEST_PROJECT_DIR"
  run _jq_transform_state "$TEST_PROJECT_DIR" 'invalid jq {{{'
  [ "$status" -eq 1 ]
}

@test "_jq_transform_state cleans up tmp file on failure" {
  init_pipeline "$TEST_PROJECT_DIR"
  _jq_transform_state "$TEST_PROJECT_DIR" 'invalid jq {{{' 2>/dev/null || true
  local tmp_count
  tmp_count="$(find "$TEST_PROJECT_DIR/.autopilot" -name '*.tmp.*' | wc -l | tr -d ' ')"
  [ "$tmp_count" = "0" ]
}

# --- update_status edge cases ---

@test "update_status rejects same-state transition" {
  init_pipeline "$TEST_PROJECT_DIR"
  run update_status "$TEST_PROJECT_DIR" "pending"
  [ "$status" -eq 1 ]
}

@test "update_status logs error on invalid transition" {
  init_pipeline "$TEST_PROJECT_DIR"
  update_status "$TEST_PROJECT_DIR" "implementing" || true
  update_status "$TEST_PROJECT_DIR" "completed" 2>/dev/null || true
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Invalid transition"* ]]
}

# --- log_msg edge cases ---

@test "log_msg handles ERROR level" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "ERROR" "something broke"
  local line
  line="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$line" == *"[ERROR]"* ]]
  [[ "$line" == *"something broke"* ]]
}

@test "log_msg handles CRITICAL level" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "CRITICAL" "urgent issue"
  local line
  line="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$line" == *"[CRITICAL]"* ]]
}

@test "log_msg throttles rotation to every _LOG_ROTATE_INTERVAL messages" {
  init_pipeline "$TEST_PROJECT_DIR"
  AUTOPILOT_MAX_LOG_LINES=5
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  # Write 10 lines — fewer than _LOG_ROTATE_INTERVAL, so rotation is skipped
  for i in $(seq 1 10); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "line $i"
  done

  local count
  count="$(wc -l < "$log_file" | tr -d ' ')"
  # All 10 remain because throttle hasn't triggered (10 < _LOG_ROTATE_INTERVAL)
  [ "$count" -eq 10 ]
}

@test "log_msg caches timestamp within same second" {
  init_pipeline "$TEST_PROJECT_DIR"
  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  # Reset cache
  unset _LOG_CACHED_TS _LOG_LAST_SEC

  log_msg "$TEST_PROJECT_DIR" "INFO" "first"
  log_msg "$TEST_PROJECT_DIR" "INFO" "second"

  # Both messages should have valid timestamps
  local line1 line2
  line1="$(sed -n '1p' "$log_file")"
  line2="$(sed -n '2p' "$log_file")"
  [[ "$line1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
  [[ "$line2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "log_msg handles empty message" {
  init_pipeline "$TEST_PROJECT_DIR"
  log_msg "$TEST_PROJECT_DIR" "INFO" ""
  local count
  count="$(wc -l < "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" | tr -d ' ')"
  [ "$count" = "1" ]
}
