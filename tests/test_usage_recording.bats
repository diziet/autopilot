#!/usr/bin/env bats
# Tests for token usage recording integration.
# Verifies record_claude_usage is called after coder, fixer, merger,
# reviewer, and spec-review agents, populating token_usage.csv.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Source metrics and dispatch-handlers (sources all deps).
  source "$BATS_TEST_DIRNAME/../lib/metrics.sh"
  source "$BATS_TEST_DIRNAME/../lib/dispatch-handlers.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Create initial state.json.
  echo '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}' \
    > "$TEST_PROJECT_DIR/.autopilot/state.json"

  # Put mock bin dir first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- Helper: create a mock Claude output JSON ---

_create_mock_output() {
  local agent="$1" task="$2"
  local input="${3:-5000}" output="${4:-2000}" cost="${5:-0.05}"
  local json_file="${TEST_PROJECT_DIR}/.autopilot/logs/${agent}-task-${task}.json"
  cat > "$json_file" << JSON
{
  "result": "mock output",
  "session_id": "sess-${agent}-${task}",
  "usage": {
    "input_tokens": ${input},
    "output_tokens": ${output},
    "cache_read_input_tokens": 1000,
    "cache_creation_input_tokens": 500
  },
  "total_cost_usd": ${cost},
  "duration_ms": 30000,
  "duration_api_ms": 25000,
  "num_turns": 10
}
JSON
}

# --- _record_agent_usage unit tests ---

@test "_record_agent_usage writes CSV row for coder" {
  _create_mock_output "coder" "1" "5000" "2000" "0.05"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  [ -f "$csv" ]
  grep -q "^1,coder," "$csv"
}

@test "_record_agent_usage writes CSV row for fixer" {
  _create_mock_output "fixer" "1" "3000" "1500" "0.03"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "fixer"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  [ -f "$csv" ]
  grep -q "^1,fixer," "$csv"
}

@test "_record_agent_usage writes CSV row for merger" {
  _create_mock_output "merger" "1" "4000" "1000" "0.02"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "merger"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  [ -f "$csv" ]
  grep -q "^1,merger," "$csv"
}

@test "_record_agent_usage records correct token values" {
  _create_mock_output "coder" "2" "8000" "3000" "0.12"

  _record_agent_usage "$TEST_PROJECT_DIR" "2" "coder"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local row
  row="$(grep "^2,coder," "$csv")"
  # Format: task,phase,in,out,cache_read,cache_create,cost,wall_ms,api_ms,turns
  [[ "$row" == "2,coder,8000,3000,1000,500,0.12,30000,25000,10" ]]
}

@test "_record_agent_usage handles missing output gracefully" {
  # No JSON file exists for this agent/task combination.
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  # CSV should exist (header only) but no data rows.
  [ -f "$csv" ]
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 0 ]
}

# --- CSV accumulation tests ---

@test "CSV accumulates rows across coder and fixer for same task" {
  _create_mock_output "coder" "1" "5000" "2000" "0.05"
  _create_mock_output "fixer" "1" "3000" "1500" "0.03"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "fixer"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 2 ]
  grep -q "^1,coder," "$csv"
  grep -q "^1,fixer," "$csv"
}

@test "CSV accumulates rows across multiple tasks" {
  _create_mock_output "coder" "1" "5000" "2000" "0.05"
  _create_mock_output "fixer" "1" "3000" "1500" "0.03"
  _create_mock_output "coder" "2" "6000" "2500" "0.06"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "fixer"
  _record_agent_usage "$TEST_PROJECT_DIR" "2" "coder"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 3 ]
  grep -q "^1,coder," "$csv"
  grep -q "^1,fixer," "$csv"
  grep -q "^2,coder," "$csv"
}

@test "CSV accumulates full pipeline: coder, fixer, merger" {
  _create_mock_output "coder" "1" "5000" "2000" "0.05"
  _create_mock_output "fixer" "1" "3000" "1500" "0.03"
  _create_mock_output "merger" "1" "4000" "1000" "0.02"

  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "fixer"
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "merger"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 3 ]

  # Verify costs are recorded correctly.
  grep "^1,coder,.*0.05" "$csv"
  grep "^1,fixer,.*0.03" "$csv"
  grep "^1,merger,.*0.02" "$csv"
}

@test "CSV header is correct for token_usage" {
  _create_mock_output "coder" "1"
  _record_agent_usage "$TEST_PROJECT_DIR" "1" "coder"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  local header
  header="$(head -1 "$csv")"
  [ "$header" = "$_USAGE_HEADER" ]
}

# --- Reviewer usage recording ---

@test "_record_reviewer_usage writes CSV rows for each persona" {
  # Source review-runner to get _record_reviewer_usage.
  source "$BATS_TEST_DIRNAME/../lib/review-runner.sh"

  # Set up task number in state.
  write_state "$TEST_PROJECT_DIR" "current_task" "3"

  # Create mock result directory with reviewer outputs.
  local result_dir
  result_dir="$(mktemp -d)"

  # Create mock reviewer output files with JSON usage data.
  local general_out="${result_dir}/general-output.json"
  cat > "$general_out" << 'JSON'
{
  "result": "NO_ISSUES_FOUND",
  "usage": {"input_tokens": 2000, "output_tokens": 500},
  "total_cost_usd": 0.01,
  "num_turns": 1
}
JSON

  local security_out="${result_dir}/security-output.json"
  cat > "$security_out" << 'JSON'
{
  "result": "Found potential XSS",
  "usage": {"input_tokens": 2500, "output_tokens": 800},
  "total_cost_usd": 0.02,
  "num_turns": 1
}
JSON

  # Write .meta files (output_file path + exit code).
  printf '%s\n%s\n' "$general_out" "0" > "${result_dir}/general.meta"
  printf '%s\n%s\n' "$security_out" "0" > "${result_dir}/security.meta"

  _record_reviewer_usage "$TEST_PROJECT_DIR" "$result_dir"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  [ -f "$csv" ]
  grep -q "^3,reviewer-general," "$csv"
  grep -q "^3,reviewer-security," "$csv"

  local data_rows
  data_rows="$(tail -n +2 "$csv" | wc -l | tr -d ' ')"
  [ "$data_rows" -eq 2 ]

  rm -rf "$result_dir"
}

@test "_record_reviewer_usage skips failed reviewers" {
  source "$BATS_TEST_DIRNAME/../lib/review-runner.sh"

  write_state "$TEST_PROJECT_DIR" "current_task" "1"

  local result_dir
  result_dir="$(mktemp -d)"

  local good_out="${result_dir}/good-output.json"
  cat > "$good_out" << 'JSON'
{"usage": {"input_tokens": 100}, "num_turns": 1}
JSON

  # One successful, one failed (exit code 124 = timeout).
  printf '%s\n%s\n' "$good_out" "0" > "${result_dir}/general.meta"
  printf '%s\n%s\n' "" "124" > "${result_dir}/security.meta"

  _record_reviewer_usage "$TEST_PROJECT_DIR" "$result_dir"

  local csv="$TEST_PROJECT_DIR/.autopilot/token_usage.csv"
  grep -q "^1,reviewer-general," "$csv"
  # Security should NOT appear (failed with exit 124).
  ! grep -q "reviewer-security" "$csv"

  rm -rf "$result_dir"
}
