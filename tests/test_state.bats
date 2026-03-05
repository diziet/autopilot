#!/usr/bin/env bats
# Tests for lib/state.sh — state management, logging, counters.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Source state.sh (which also sources config.sh)
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
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

  # Write 25 lines
  for i in $(seq 1 25); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "line $i"
  done

  local count
  count="$(wc -l < "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" | tr -d ' ')"
  # After rotation, should have ~half of max (10) plus any written after
  [ "$count" -le 20 ]
  [ "$count" -gt 0 ]
}

@test "log_msg rotation preserves most recent lines" {
  init_pipeline "$TEST_PROJECT_DIR"
  AUTOPILOT_MAX_LOG_LINES=10

  for i in $(seq 1 15); do
    log_msg "$TEST_PROJECT_DIR" "INFO" "line $i"
  done

  # The last line should be "line 15"
  local last_line
  last_line="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
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
