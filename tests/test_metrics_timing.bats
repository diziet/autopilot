#!/usr/bin/env bats
# Tests for wall-clock timing, test suite duration recording,
# and phase summaries with test time.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/metrics.sh"
source "$BATS_TEST_DIRNAME/../lib/test-summary.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"
}

# === Wall-clock timing: walltime file override ===

@test "record_claude_usage uses walltime file to override wall_ms" {
  # Create a Claude output JSON with internal duration of 3s.
  local json_file="${TEST_PROJECT_DIR}/agent.json"
  cat > "$json_file" << 'JSON'
{
  "usage": {"input_tokens": 100, "output_tokens": 50},
  "total_cost_usd": 0.01,
  "duration_ms": 3000,
  "duration_api_ms": 2000,
  "num_turns": 2
}
JSON

  # Write a walltime file indicating 600s real elapsed time.
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "600" > "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-1.walltime"

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json_file"

  # The wall_ms in the CSV should be 600000 (600s * 1000), not 3000.
  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")"
  local wall_ms_col
  wall_ms_col="$(echo "$row" | cut -d',' -f8)"
  [ "$wall_ms_col" = "600000" ]
}

@test "record_claude_usage falls back to JSON wall_ms without walltime file" {
  local json_file="${TEST_PROJECT_DIR}/agent.json"
  cat > "$json_file" << 'JSON'
{
  "usage": {"input_tokens": 100, "output_tokens": 50},
  "duration_ms": 5000,
  "duration_api_ms": 4000,
  "num_turns": 1
}
JSON

  record_claude_usage "$TEST_PROJECT_DIR" "1" "coder" "$json_file"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/token_usage.csv")"
  local wall_ms_col
  wall_ms_col="$(echo "$row" | cut -d',' -f8)"
  [ "$wall_ms_col" = "5000" ]
}

@test "record_claude_usage removes walltime file after reading" {
  local json_file="${TEST_PROJECT_DIR}/agent.json"
  cat > "$json_file" << 'JSON'
{"usage": {"input_tokens": 10}, "duration_ms": 1000}
JSON

  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "120" > "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-2.walltime"

  record_claude_usage "$TEST_PROJECT_DIR" "2" "coder" "$json_file"

  [ ! -f "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-2.walltime" ]
}

@test "wall_ms override shows in METRICS timing log line" {
  local json_file="${TEST_PROJECT_DIR}/agent.json"
  cat > "$json_file" << 'JSON'
{
  "usage": {"input_tokens": 100},
  "duration_ms": 3000,
  "duration_api_ms": 2000,
  "num_turns": 1
}
JSON

  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "1800" > "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-5.walltime"

  record_claude_usage "$TEST_PROJECT_DIR" "5" "coder" "$json_file"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  # wall should be 1800s (from walltime file), not 3s
  grep -q "METRICS: timing task 5 coder — wall=1800s" "$log_file"
}

# === Test suite duration accumulation ===

@test "accumulate_test_duration adds seconds to state" {
  accumulate_test_duration "$TEST_PROJECT_DIR" "30"

  local total
  total="$(jq -r '.test_suite_total_sec // 0' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$total" -eq 30 ]
}

@test "accumulate_test_duration accumulates across multiple calls" {
  accumulate_test_duration "$TEST_PROJECT_DIR" "30"
  accumulate_test_duration "$TEST_PROJECT_DIR" "45"
  accumulate_test_duration "$TEST_PROJECT_DIR" "15"

  local total
  total="$(jq -r '.test_suite_total_sec // 0' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$total" -eq 90 ]
}

@test "accumulate_test_duration ignores zero and non-numeric" {
  accumulate_test_duration "$TEST_PROJECT_DIR" "0"
  accumulate_test_duration "$TEST_PROJECT_DIR" "abc"
  accumulate_test_duration "$TEST_PROJECT_DIR" ""

  local total
  total="$(jq -r '.test_suite_total_sec // "missing"' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$total" = "missing" ]
}

@test "reset_phase_durations clears test_suite_total_sec" {
  accumulate_test_duration "$TEST_PROJECT_DIR" "60"

  reset_phase_durations "$TEST_PROJECT_DIR"

  local total
  total="$(jq -r '.test_suite_total_sec // "gone"' \
    "$TEST_PROJECT_DIR/.autopilot/state.json")"
  [ "$total" = "gone" ]
}

# === log_test_suite_metrics ===

@test "log_test_suite_metrics writes METRICS: test_suite line" {
  log_test_suite_metrics "$TEST_PROJECT_DIR" "42" "120" "0" "50" "48"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "METRICS: test_suite task 42 — wall=120s exit=0 tests_total=50 tests_passed=48" \
    "$log_file"
}

@test "log_test_suite_metrics handles failure exit code" {
  log_test_suite_metrics "$TEST_PROJECT_DIR" "10" "30" "1" "20" "18"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "METRICS: test_suite task 10 — wall=30s exit=1 tests_total=20 tests_passed=18" \
    "$log_file"
}

# === _extract_test_counts ===

@test "extract_test_counts parses bats TAP output" {
  local output
  output="$(printf 'ok 1 test one\nok 2 test two\nnot ok 3 test three\n')"
  local counts
  counts="$(_extract_test_counts "$output")"
  local total passed
  read -r total passed <<< "$counts"
  [ "$total" -eq 3 ]
  [ "$passed" -eq 2 ]
}

@test "extract_test_counts parses pytest output" {
  local output="=== 10 passed, 2 failed in 5.21s ==="
  local counts
  counts="$(_extract_test_counts "$output")"
  local total passed
  read -r total passed <<< "$counts"
  [ "$total" -eq 12 ]
  [ "$passed" -eq 10 ]
}

@test "extract_test_counts returns 0 0 for empty output" {
  local counts
  counts="$(_extract_test_counts "")"
  local total passed
  read -r total passed <<< "$counts"
  [ "$total" -eq 0 ]
  [ "$passed" -eq 0 ]
}

# === Phase summaries include test time ===

@test "record_phase_durations includes test_total_sec in CSV" {
  jq '.phase_durations = {"implementing": 100, "merging": 20} | .test_suite_total_sec = 45' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "8" "30"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")"
  # Format: task,pr,impl,test_fix,pr_open,review,fix,merge,test_total,total
  local test_total_col
  test_total_col="$(echo "$row" | cut -d',' -f9)"
  [ "$test_total_col" = "45" ]
}

@test "record_phase_durations logs test= field in METRICS line" {
  jq '.phase_durations = {"implementing": 500} | .test_suite_total_sec = 200' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  record_phase_durations "$TEST_PROJECT_DIR" "3" "15"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "test=200s" "$log_file"
}

@test "phase header includes test_total_sec column" {
  [[ "$_PHASE_HEADER" == *"test_total_sec"* ]]
}

@test "record_phase_durations defaults test_total_sec to 0" {
  # No test_suite_total_sec in state
  record_phase_durations "$TEST_PROJECT_DIR" "1" "10"

  local row
  row="$(tail -1 "$TEST_PROJECT_DIR/.autopilot/phase_timing.csv")"
  # Format: task,pr,impl,test_fix,pr_open,review,fix,merge,test_total,total
  local test_total_col
  test_total_col="$(echo "$row" | cut -d',' -f9)"
  [ "$test_total_col" = "0" ]
}
