#!/usr/bin/env bats
# Tests for lib/metrics.sh — CSV tracking for per-task metrics,
# phase timing, token usage, TIMER tags, and header auto-update.

load helpers/test_template

# Source libs once at file level (not per-test).
source "$BATS_TEST_DIRNAME/../lib/metrics.sh"

setup() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  TEST_MOCK_BIN="${BATS_TEST_TMPDIR}/mocks"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs" \
           "$TEST_PROJECT_DIR/.autopilot/locks" \
           "$TEST_MOCK_BIN"

  _unset_autopilot_vars
  load_config "$TEST_PROJECT_DIR"

  # Create initial state.json.
  printf '%s\n' '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}' \
    > "$TEST_PROJECT_DIR/.autopilot/state.json"

  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

teardown() {
  : # BATS_TEST_TMPDIR is auto-cleaned
}

# === Exit Code Constants ===

@test "METRICS_OK is 0" {
  [ "$METRICS_OK" -eq 0 ]
}

@test "METRICS_ERROR is 1" {
  [ "$METRICS_ERROR" -eq 1 ]
}

# === CSV Headers ===

@test "metrics header contains expected columns" {
  [[ "$_METRICS_HEADER" == *"task_number"* ]]
  [[ "$_METRICS_HEADER" == *"duration_minutes"* ]]
  [[ "$_METRICS_HEADER" == *"comment_count"* ]]
  [[ "$_METRICS_HEADER" == *"files_changed"* ]]
}

@test "phase header includes test_fixing_sec and reviewed_sec columns" {
  [[ "$_PHASE_HEADER" == *"test_fixing_sec"* ]]
  [[ "$_PHASE_HEADER" == *"implementing_sec"* ]]
  [[ "$_PHASE_HEADER" == *"reviewed_sec"* ]]
  [[ "$_PHASE_HEADER" == *"merging_sec"* ]]
  [[ "$_PHASE_HEADER" == *"total_sec"* ]]
}

@test "usage header contains token and cost columns" {
  [[ "$_USAGE_HEADER" == *"input_tokens"* ]]
  [[ "$_USAGE_HEADER" == *"cost_usd"* ]]
  [[ "$_USAGE_HEADER" == *"num_turns"* ]]
}

# === _auto_update_header ===

@test "auto_update_header creates new file with header" {
  local csv_file="${TEST_PROJECT_DIR}/test.csv"
  _auto_update_header "$csv_file" "col_a,col_b,col_c"
  [ -f "$csv_file" ]
  [ "$(head -1 "$csv_file")" = "col_a,col_b,col_c" ]
}

@test "auto_update_header preserves data rows on schema change" {
  local csv_file="${TEST_PROJECT_DIR}/test.csv"
  echo "old_col_a,old_col_b" > "$csv_file"
  echo "1,2" >> "$csv_file"
  echo "3,4" >> "$csv_file"

  _auto_update_header "$csv_file" "new_col_a,new_col_b,new_col_c"
  [ "$(head -1 "$csv_file")" = "new_col_a,new_col_b,new_col_c" ]
  [ "$(sed -n '2p' "$csv_file")" = "1,2" ]
  [ "$(sed -n '3p' "$csv_file")" = "3,4" ]
}

@test "auto_update_header does nothing when header matches" {
  local csv_file="${TEST_PROJECT_DIR}/test.csv"
  echo "col_a,col_b" > "$csv_file"
  echo "1,2" >> "$csv_file"

  local before_mtime
  before_mtime="$(stat -f '%m' "$csv_file" 2>/dev/null || stat -c '%Y' "$csv_file")"
  sleep 1
  _auto_update_header "$csv_file" "col_a,col_b"
  local after_mtime
  after_mtime="$(stat -f '%m' "$csv_file" 2>/dev/null || stat -c '%Y' "$csv_file")"
  [ "$before_mtime" = "$after_mtime" ]
}

# === _init_metrics_file ===

@test "init_metrics_file creates metrics.csv with header" {
  _init_metrics_file "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/metrics.csv" ]
  [ "$(head -1 "$TEST_PROJECT_DIR/.autopilot/metrics.csv")" = "$_METRICS_HEADER" ]
}

@test "init_metrics_file fails when .autopilot dir missing" {
  run _init_metrics_file "/nonexistent/path"
  [ "$status" -ne 0 ]
}

# === _init_phase_file ===

@test "init_phase_file creates phase_timing.csv with header" {
  _init_phase_file "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv" ]
  [ "$(head -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")" = "$_PHASE_HEADER" ]
}

# === _init_usage_file ===

@test "init_usage_file creates token_usage.csv with header" {
  _init_usage_file "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/token_usage.csv" ]
  [ "$(head -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")" = "$_USAGE_HEADER" ]
}

@test "init_usage_file auto-updates header on schema change" {
  local usage_file="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  echo "old_header" > "$usage_file"
  echo "1,coder,100,50,10,5,0.50,1000,500,3" >> "$usage_file"

  _init_usage_file "$TEST_PROJECT_DIR"
  [ "$(head -1 "$usage_file")" = "$_USAGE_HEADER" ]
  [ "$(sed -n '2p' "$usage_file")" = "1,coder,100,50,10,5,0.50,1000,500,3" ]
}

# === _validate_int ===

@test "validate_int accepts valid integers" {
  [ "$(_validate_int "42")" = "42" ]
  [ "$(_validate_int "0")" = "0" ]
  [ "$(_validate_int "99999")" = "99999" ]
}

@test "validate_int defaults invalid values to 0" {
  [ "$(_validate_int "abc")" = "0" ]
  [ "$(_validate_int "")" = "0" ]
  [ "$(_validate_int "-5")" = "0" ]
  [ "$(_validate_int "1.5")" = "0" ]
}

# === _validate_decimal ===

@test "validate_decimal accepts valid decimals" {
  [ "$(_validate_decimal "3.14")" = "3.14" ]
  [ "$(_validate_decimal "0")" = "0" ]
  [ "$(_validate_decimal "-1.5")" = "-1.5" ]
  [ "$(_validate_decimal "42")" = "42" ]
}

@test "validate_decimal defaults invalid values to 0" {
  [ "$(_validate_decimal "abc")" = "0" ]
  [ "$(_validate_decimal "")" = "0" ]
  [ "$(_validate_decimal "1.2.3")" = "0" ]
}

# === _jq_field ===

@test "jq_field extracts numeric fields from JSON" {
  local json='{"additions":42,"deletions":10}'
  [ "$(_jq_field "$json" "additions")" = "42" ]
  [ "$(_jq_field "$json" "deletions")" = "10" ]
}

@test "jq_field returns 0 for missing fields" {
  local json='{"additions":42}'
  [ "$(_jq_field "$json" "missing_field")" = "0" ]
}

# === timer_log ===

@test "timer_log writes TIMER tag to log" {
  local start_epoch
  start_epoch="$(date -u '+%s')"
  timer_log "$TEST_PROJECT_DIR" "test step" "$start_epoch"

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  [ -f "$log_file" ]
  grep -q "TIMER: test step" "$log_file"
}

@test "timer_log includes elapsed seconds" {
  local start_epoch
  start_epoch="$(( $(date -u '+%s') - 5 ))"
  timer_log "$TEST_PROJECT_DIR" "slow step" "$start_epoch"

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -q "TIMER: slow step ([0-9]*s)" "$log_file"
}

# === _parse_iso_epoch ===

@test "parse_iso_epoch converts ISO timestamp to epoch" {
  local epoch
  epoch="$(_parse_iso_epoch "2024-01-15T10:30:00Z")"
  [[ "$epoch" =~ ^[0-9]+$ ]]
  [ "$epoch" -gt 1700000000 ]
}

@test "parse_iso_epoch fails on empty input" {
  run _parse_iso_epoch ""
  [ "$status" -ne 0 ]
}

@test "parse_iso_epoch fails on 'unknown'" {
  run _parse_iso_epoch "unknown"
  [ "$status" -ne 0 ]
}

# === _calc_duration_minutes ===

@test "calc_duration_minutes computes correct minutes" {
  local start="2024-01-15T10:00:00Z"
  local end="2024-01-15T10:30:00Z"
  local result
  result="$(_calc_duration_minutes "$start" "$end")"
  [ "$result" -eq 30 ]
}

@test "calc_duration_minutes returns 0 for unknown start" {
  local result
  result="$(_calc_duration_minutes "unknown" "2024-01-15T10:30:00Z")"
  [ "$result" = "0" ]
}

@test "calc_duration_minutes returns 0 for empty start" {
  local result
  result="$(_calc_duration_minutes "" "2024-01-15T10:30:00Z")"
  [ "$result" = "0" ]
}

# === record_task_start ===

@test "record_task_start writes timestamps to state" {
  record_task_start "$TEST_PROJECT_DIR" "5"

  local started_at
  started_at="$(read_state "$TEST_PROJECT_DIR" "task_started_at")"
  [ -n "$started_at" ]
  [[ "$started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]

  local entered_at
  entered_at="$(read_state "$TEST_PROJECT_DIR" "phase_entered_at")"
  [ -n "$entered_at" ]
}

@test "record_task_start logs the task number" {
  record_task_start "$TEST_PROJECT_DIR" "7"
  grep -q "METRICS: recorded start time for task 7" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

# === record_task_complete ===

@test "record_task_complete appends CSV row" {
  # Mock gh so it doesn't try real API calls
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":10,"deletions":5,"changedFiles":3,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift  # skip timeout value
"$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  # Set up state with a start time
  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 1

  record_task_complete "$TEST_PROJECT_DIR" "3" "42" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  [ -f "$csv" ]
  # Should have header + 1 data row
  [ "$(wc -l < "$csv" | tr -d ' ')" -eq 2 ]
  grep -q "^3,merged,42," "$csv"
}

@test "record_task_complete deduplicates by task number" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":0,"deletions":0,"changedFiles":0,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"

  record_task_complete "$TEST_PROJECT_DIR" "3" "42" "owner/repo"
  record_task_complete "$TEST_PROJECT_DIR" "3" "42" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 1 ]
}

@test "record_task_complete handles missing start time" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":0,"deletions":0,"changedFiles":0,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  # No task_started_at in state — should still work
  record_task_complete "$TEST_PROJECT_DIR" "1" "10" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  grep -q "^1,merged,10,unknown," "$csv"
}

@test "record_task_complete validates numeric fields" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":"bad","deletions":null,"changedFiles":"","comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"

  record_task_complete "$TEST_PROJECT_DIR" "1" "10" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  [ -f "$csv" ]
  # Should have valid CSV even with bad input
  local row
  row="$(tail -1 "$csv")"
  [[ "$row" =~ ^1,merged,10, ]]
}

@test "record_task_complete accepts custom status parameter" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":0,"deletions":0,"changedFiles":0,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"

  record_task_complete "$TEST_PROJECT_DIR" "1" "10" "owner/repo" "failed"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  grep -q "^1,failed,10," "$csv"
}

@test "record_task_complete defaults status to merged" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":0,"deletions":0,"changedFiles":0,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"

  record_task_complete "$TEST_PROJECT_DIR" "2" "20" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  grep -q "^2,merged,20," "$csv"
}

# === get_pr_stats ===

@test "get_pr_stats returns empty stats for empty pr_number" {
  local result
  result="$(get_pr_stats "" "owner/repo")"
  [ "$(echo "$result" | jq -r '.additions')" = "0" ]
}

@test "get_pr_stats returns empty stats for empty repo" {
  local result
  result="$(get_pr_stats "42" "")"
  [ "$(echo "$result" | jq -r '.additions')" = "0" ]
}

@test "get_pr_stats falls back on gh failure" {
  # Mock gh to fail
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  local result
  result="$(get_pr_stats "42" "owner/repo")"
  [ "$(echo "$result" | jq -r '.additions')" = "0" ]
}

# === _accumulate_phase_time ===

@test "accumulate_phase_time adds seconds to phase_durations" {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Set entered_at to 60 seconds ago
  local entered_epoch
  entered_epoch="$(date -u '+%s')"
  entered_epoch=$(( entered_epoch - 60 ))
  local entered_at
  # Generate ISO timestamp from epoch
  if date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    entered_at="$(date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    entered_at="$(date -u -d "@$entered_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  write_state "$TEST_PROJECT_DIR" "phase_entered_at" "$entered_at"

  _accumulate_phase_time "$TEST_PROJECT_DIR" "implementing" "$now"

  local durations
  durations="$(jq -r '.phase_durations.implementing // 0' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$durations" -ge 59 ]
  [ "$durations" -le 62 ]
}

@test "accumulate_phase_time does nothing without phase_entered_at" {
  _accumulate_phase_time "$TEST_PROJECT_DIR" "implementing" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local durations
  durations="$(jq -r '.phase_durations // "null"' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$durations" = "null" ]
}

@test "accumulate_phase_time accumulates across multiple calls" {
  # First accumulation: 30 seconds in implementing
  local base_epoch
  base_epoch="$(date -u '+%s')"
  local t1_epoch=$(( base_epoch - 60 ))
  local t2_epoch=$(( base_epoch - 30 ))

  local t1_ts t2_ts t3_ts
  if date -r "$t1_epoch" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    t1_ts="$(date -r "$t1_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
    t2_ts="$(date -r "$t2_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
    t3_ts="$(date -r "$base_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    t1_ts="$(date -u -d "@$t1_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
    t2_ts="$(date -u -d "@$t2_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
    t3_ts="$(date -u -d "@$base_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  write_state "$TEST_PROJECT_DIR" "phase_entered_at" "$t1_ts"
  _accumulate_phase_time "$TEST_PROJECT_DIR" "implementing" "$t2_ts"

  # Second accumulation: 30 more seconds
  write_state "$TEST_PROJECT_DIR" "phase_entered_at" "$t2_ts"
  _accumulate_phase_time "$TEST_PROJECT_DIR" "implementing" "$t3_ts"

  local total
  total="$(jq -r '.phase_durations.implementing // 0' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$total" -ge 58 ]
  [ "$total" -le 62 ]
}

# === reset_phase_durations ===

@test "reset_phase_durations clears phase data" {
  # Add some phase data
  jq '.phase_durations = {"implementing": 100} | .phase_entered_at = "2024-01-15T10:00:00Z"' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  reset_phase_durations "$TEST_PROJECT_DIR"

  local pd_result
  pd_result="$(jq -r '.phase_durations // "gone"' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$pd_result" = "gone" ]

  local pe_result
  pe_result="$(jq -r '.phase_entered_at // "gone"' "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$pe_result" = "gone" ]
}

@test "reset_phase_durations preserves other state fields" {
  write_state "$TEST_PROJECT_DIR" "status" "pending"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 5

  jq '.phase_durations = {"implementing": 100}' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  reset_phase_durations "$TEST_PROJECT_DIR"

  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "pending" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "current_task")" = "5" ]
}

# === record_phase_transition ===

@test "record_phase_transition accumulates time and resets entered_at" {
  # Set up a phase entered 60 seconds ago
  local entered_epoch
  entered_epoch="$(( $(date -u '+%s') - 60 ))"
  local entered_ts
  if date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    entered_ts="$(date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    entered_ts="$(date -u -d "@$entered_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  write_state "$TEST_PROJECT_DIR" "phase_entered_at" "$entered_ts"

  record_phase_transition "$TEST_PROJECT_DIR" "implementing"

  # Check that implementing duration was accumulated
  local impl_sec
  impl_sec="$(jq -r '.phase_durations.implementing // 0' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$impl_sec" -ge 58 ]

  # Check phase_entered_at was updated
  local new_entered
  new_entered="$(read_state "$TEST_PROJECT_DIR" "phase_entered_at")"
  [ -n "$new_entered" ]
  [ "$new_entered" != "$entered_ts" ]
}

# === record_phase_durations ===

@test "record_phase_durations writes CSV row" {
  # Set up state with phase durations and status=merging (no phase_entered_at
  # so finalization is a no-op, testing pure read of stored durations)
  jq '.phase_durations = {"implementing": 120, "test_fixing": 30, "pr_open": 60, "reviewed": 45, "fixing": 90, "merging": 15} | .status = "merging"' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "5" "42"

  local phase_csv="$TEST_PROJECT_DIR/.autopilot/phase_timing.csv"
  [ -f "$phase_csv" ]
  # Header + 1 data row
  [ "$(wc -l < "$phase_csv" | tr -d ' ')" -eq 2 ]

  # Check CSV row content
  local row
  row="$(tail -1 "$phase_csv")"
  # task_number=5, pr_number=42, implementing=120, test_fixing=30
  [[ "$row" =~ ^5,42,120,30, ]]
}

@test "record_phase_durations includes test_fixing_sec" {
  jq '.phase_durations = {"implementing": 100, "test_fixing": 55}' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "3" "20"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")"
  # Format: task,pr,impl,test_fix,pr_open,review,fix,merge,total
  local test_fix_col
  test_fix_col="$(echo "$row" | cut -d',' -f4)"
  [ "$test_fix_col" = "55" ]
}

@test "record_phase_durations calculates total_sec" {
  jq '.phase_durations = {"implementing": 10, "test_fixing": 20, "pr_open": 30, "reviewed": 40, "fixing": 50, "merging": 60}' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "1" "10"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")"
  local total_col
  total_col="$(echo "$row" | cut -d',' -f9)"
  # 10+20+30+40+50+60 = 210
  [ "$total_col" = "210" ]
}

@test "record_phase_durations deduplicates by task number" {
  jq '.phase_durations = {"implementing": 100}' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "5" "42"
  record_phase_durations "$TEST_PROJECT_DIR" "5" "42"

  local phase_csv="$TEST_PROJECT_DIR/.autopilot/phase_timing.csv"
  local data_rows
  data_rows="$(tail -n +2 "$phase_csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 1 ]
}

@test "record_phase_durations finalization accumulates current phase time" {
  # Set status to implementing with a known base and phase_entered_at 60s ago
  local entered_epoch
  entered_epoch="$(( $(date -u '+%s') - 60 ))"
  local entered_ts
  if date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    entered_ts="$(date -r "$entered_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    entered_ts="$(date -u -d "@$entered_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  jq --arg ts "$entered_ts" \
    '.status = "implementing" | .phase_entered_at = $ts | .phase_durations = {"implementing": 300}' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "7" "50"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")"
  local impl_col
  impl_col="$(echo "$row" | cut -d',' -f3)"
  # Base (300) + ~60 seconds elapsed = ~360
  [ "$impl_col" -ge 358 ]
  [ "$impl_col" -le 362 ]
}

@test "record_phase_durations handles missing phase_durations" {
  # state has no phase_durations at all
  record_phase_durations "$TEST_PROJECT_DIR" "1" "10"

  local phase_csv="$TEST_PROJECT_DIR/.autopilot/phase_timing.csv"
  local row
  row="$(tail -1 "$phase_csv")"
  # All phase times should be 0, total should be 0
  [[ "$row" =~ ^1,10,0,0,0,0,0,0,0$ ]]
}

# === record_claude_usage ===

@test "record_claude_usage appends token usage CSV row" {
  local json_file="${TEST_PROJECT_DIR}/claude_output.json"
  cat > "$json_file" << 'JSON'
{
  "result": "some output",
  "usage": {
    "input_tokens": 5000,
    "output_tokens": 2000,
    "cache_read_input_tokens": 1000,
    "cache_creation_input_tokens": 500
  },
  "total_cost_usd": 0.15,
  "duration_ms": 30000,
  "duration_api_ms": 25000,
  "num_turns": 12
}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "3" "coder" "$json_file"

  local usage_csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  [ -f "$usage_csv" ]
  [ "$(wc -l < "$usage_csv" | tr -d ' ')" -eq 2 ]

  local row
  row="$(tail -1 "$usage_csv")"
  [ "$row" = "3,coder,5000,2000,1000,500,0.15,30000,25000,12" ]
}

@test "record_claude_usage handles missing JSON file gracefully" {
  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "/nonexistent/file.json"

  local usage_csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  # Should only have header, no data row
  [ "$(wc -l < "$usage_csv" | tr -d ' ')" -le 1 ]
}

@test "record_claude_usage handles malformed JSON gracefully" {
  local json_file="${TEST_PROJECT_DIR}/bad.json"
  echo "not valid json" > "$json_file"

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json_file"

  local usage_csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  # Should still write a row with all 0s
  local row
  row="$(tail -1 "$usage_csv")"
  [ "$row" = "1,coder,0,0,0,0,0,0,0,0" ]
}

@test "record_claude_usage handles partial JSON fields" {
  local json_file="${TEST_PROJECT_DIR}/partial.json"
  cat > "$json_file" << 'JSON'
{
  "result": "output",
  "usage": {
    "input_tokens": 1000
  },
  "num_turns": 5
}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "2" "fixer" "$json_file"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")"
  # input=1000, others=0, turns=5
  [ "$row" = "2,fixer,1000,0,0,0,0,0,0,5" ]
}

@test "record_claude_usage logs timing breakdown" {
  local json_file="${TEST_PROJECT_DIR}/usage.json"
  cat > "$json_file" << 'JSON'
{
  "usage": {"input_tokens": 100, "output_tokens": 50},
  "total_cost_usd": 0.01,
  "duration_ms": 10000,
  "duration_api_ms": 8000,
  "num_turns": 3
}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json_file"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "METRICS: usage task 1 coder" "$log_file"
  grep -q "METRICS: timing task 1 coder" "$log_file"
}

@test "record_claude_usage validates task_number as integer" {
  local json_file="${TEST_PROJECT_DIR}/usage.json"
  cat > "$json_file" << 'JSON'
{"usage":{"input_tokens":100},"num_turns":1}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "bad,data" "coder" "$json_file"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")"
  # bad,data should be validated to 0
  [[ "$row" =~ ^0,coder, ]]
}

@test "record_claude_usage validates cost as decimal" {
  local json_file="${TEST_PROJECT_DIR}/cost.json"
  cat > "$json_file" << 'JSON'
{
  "usage": {"input_tokens": 100},
  "total_cost_usd": 1.234
}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json_file"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")"
  [[ "$row" == *"1.234"* ]]
}

# === Header auto-update integration ===

@test "metrics CSV header updates on schema change preserving data" {
  # Create a metrics CSV with an old header
  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  echo "task_number,status,old_col" > "$csv"
  echo "1,merged,old_val" >> "$csv"
  echo "2,merged,old_val2" >> "$csv"

  _init_metrics_file "$TEST_PROJECT_DIR"

  # Header should now be the new one
  [ "$(head -1 "$csv")" = "$_METRICS_HEADER" ]
  # Data rows preserved
  [ "$(sed -n '2p' "$csv")" = "1,merged,old_val" ]
  [ "$(sed -n '3p' "$csv")" = "2,merged,old_val2" ]
}

@test "phase CSV header updates on schema change" {
  local csv="$TEST_PROJECT_DIR/.autopilot/phase_timing.csv"
  echo "old_header" > "$csv"
  echo "1,42,100,200" >> "$csv"

  _init_phase_file "$TEST_PROJECT_DIR"

  [ "$(head -1 "$csv")" = "$_PHASE_HEADER" ]
  [ "$(sed -n '2p' "$csv")" = "1,42,100,200" ]
}

# === Multiple task recording ===

@test "multiple tasks recorded correctly in metrics CSV" {
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
echo '{"additions":5,"deletions":2,"changedFiles":1,"comments":[]}'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/bin/bash
shift; "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T10:00:00Z"
  record_task_complete "$TEST_PROJECT_DIR" "1" "10" "owner/repo"

  write_state "$TEST_PROJECT_DIR" "task_started_at" "2024-01-15T11:00:00Z"
  # Remove dedup guard for task 2
  record_task_complete "$TEST_PROJECT_DIR" "2" "11" "owner/repo"

  local csv="$TEST_PROJECT_DIR/.autopilot/metrics.csv"
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 2 ]
  grep -q "^1,merged,10," "$csv"
  grep -q "^2,merged,11," "$csv"
}

@test "multiple usage entries for same task different phases" {
  local json1="${TEST_PROJECT_DIR}/coder.json"
  cat > "$json1" << 'JSON'
{"usage":{"input_tokens":1000,"output_tokens":500},"num_turns":5}
JSON

  local json2="${TEST_PROJECT_DIR}/fixer.json"
  cat > "$json2" << 'JSON'
{"usage":{"input_tokens":2000,"output_tokens":800},"num_turns":3}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json1"
  record_claude_usage "$TEST_PROJECT_DIR" "1" "fixer" "$json2"

  local usage_csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local data_rows
  data_rows="$(tail -n +2 "$usage_csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 2 ]
  grep -q "^1,coder," "$usage_csv"
  grep -q "^1,fixer," "$usage_csv"
}
