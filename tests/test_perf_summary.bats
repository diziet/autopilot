#!/usr/bin/env bats
# Tests for lib/perf-summary.sh — performance summary table formatting
# and background PR comment posting.

load helpers/test_template

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Source perf-summary.sh (which sources state.sh, metrics.sh, tasks.sh).
  source "$BATS_TEST_DIRNAME/../lib/perf-summary.sh"
  # Source git-ops for resolve_task_title / get_repo_slug.
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Create initial state.json.
  echo '{"status":"merged","current_task":47,"retry_count":0,"test_fix_retries":0}' \
    > "$TEST_PROJECT_DIR/.autopilot/state.json"

  # Create a tasks.md with a task heading.
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'TASKS'
## Task 47: Finalize lock to prevent double-advancing after merge

Some task body here.

## Task 48: Next task

Next task body.
TASKS

  # Put mock bin dir first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"

  # Mock timeout.
  cat > "$TEST_MOCK_BIN/timeout" << 'MOCK'
#!/usr/bin/env bash
shift; exec "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/timeout"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- Helper to create agent output JSON ---

_create_agent_json() {
  local file="$1" wall_ms="$2" api_ms="$3" turns="$4"
  local in_tok="$5" out_tok="$6" cache_r="$7" cache_c="$8" cost="$9"
  cat > "$file" << JSON
{
  "duration_ms": ${wall_ms},
  "duration_api_ms": ${api_ms},
  "num_turns": ${turns},
  "usage": {
    "input_tokens": ${in_tok},
    "output_tokens": ${out_tok},
    "cache_read_input_tokens": ${cache_r},
    "cache_creation_input_tokens": ${cache_c}
  },
  "total_cost_usd": ${cost}
}
JSON
}

# === Number formatting ===

@test "format_number adds comma separators" {
  [ "$(_format_number "1234567")" = "1,234,567" ]
  [ "$(_format_number "0")" = "0" ]
  [ "$(_format_number "42")" = "42" ]
}

@test "format_ms_as_sec converts milliseconds" {
  [ "$(_format_ms_as_sec "900000")" = "900s" ]
  [ "$(_format_ms_as_sec "0")" = "0s" ]
  [ "$(_format_ms_as_sec "1500")" = "1s" ]
}

@test "format_sec_duration handles various ranges" {
  [ "$(_format_sec_duration "0")" = "0s" ]
  [ "$(_format_sec_duration "45")" = "45s" ]
  [ "$(_format_sec_duration "90")" = "1m30s" ]
  [ "$(_format_sec_duration "120")" = "2m" ]
  [ "$(_format_sec_duration "3240")" = "54m" ]
  [ "$(_format_sec_duration "3660")" = "1h1m" ]
  [ "$(_format_sec_duration "7200")" = "2h" ]
}

# === Agent row extraction ===

@test "extract_agent_row parses JSON correctly" {
  local json="${TEST_PROJECT_DIR}/test.json"
  _create_agent_json "$json" 900000 318000 69 71 15528 4436946 69202 3.04

  local result
  result="$(_extract_agent_row "$json")"
  [ "$result" = "900000|318000|69|71|15528|4436946|69202|3.04" ]
}

@test "extract_agent_row returns empty for missing file" {
  local result
  result="$(_extract_agent_row "/nonexistent/file.json")" || true
  [ -z "$result" ]
}

# === Phase row formatting ===

@test "format_phase_row produces valid markdown row" {
  local result
  result="$(_format_phase_row "Coder" "900000|318000|69|71|15528|4436946|69202|3.04" "0")"
  [[ "$result" == "| Coder |"* ]]
  [[ "$result" == *"| 900s |"* ]]
  [[ "$result" == *"| 318s |"* ]]
  [[ "$result" == *"| 69 |"* ]]
  [[ "$result" == *'| $3.04 |' ]]
}

@test "format_phase_only_row shows dashes for agent columns" {
  local result
  result="$(_format_phase_only_row "Test gate" "45")"
  [[ "$result" == "| Test gate | 45s |"* ]]
  # Count the dash columns
  local dash_count
  dash_count="$(echo "$result" | grep -o '—' | wc -l | tr -d ' ')"
  [ "$dash_count" -eq 8 ]
}

# === Task description extraction ===

@test "extract_task_description gets heading from tasks.md" {
  local result
  result="$(_extract_task_description "$TEST_PROJECT_DIR" "47")"
  [ "$result" = "Task 47: Finalize lock to prevent double-advancing after merge" ]
}

@test "extract_task_description falls back for missing task" {
  local result
  result="$(_extract_task_description "$TEST_PROJECT_DIR" "999")"
  [ "$result" = "Task 999" ]
}

# === Phase timing reading ===

@test "read_phase_timing parses CSV correctly" {
  local csv="${TEST_PROJECT_DIR}/.autopilot/phase_timing.csv"
  echo "task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,reviewed_sec,fixing_sec,merging_sec,total_sec" > "$csv"
  echo "47,100,120,45,60,170,634,19,1048" >> "$csv"

  local result
  result="$(_read_phase_timing "$TEST_PROJECT_DIR" "47")"
  [ "$result" = "120|45|60|170|634|19" ]
}

@test "read_phase_timing fails for missing task" {
  local csv="${TEST_PROJECT_DIR}/.autopilot/phase_timing.csv"
  echo "task_number,pr_number,implementing_sec" > "$csv"
  echo "1,10,100" >> "$csv"

  run _read_phase_timing "$TEST_PROJECT_DIR" "999"
  [ "$status" -ne 0 ]
}

# === Full table building — all phases present ===

@test "build_performance_summary includes all phases" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"

  # Create agent JSON files for all phases.
  _create_agent_json "${logs}/coder-task-47.json" 900000 318000 69 71 15528 4436946 69202 3.04
  _create_agent_json "${logs}/fixer-task-47.json" 634000 205000 45 83 12340 4412000 1200 3.11
  _create_agent_json "${logs}/reviewer-security-task-47.json" 170000 170000 5 250 3685 70020 13784 0.55
  _create_agent_json "${logs}/merger-task-47.json" 19000 19000 1 3 737 14004 0 0.11

  # Create phase timing CSV with test gate data.
  local csv="${TEST_PROJECT_DIR}/.autopilot/phase_timing.csv"
  echo "task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,reviewed_sec,fixing_sec,merging_sec,total_sec" > "$csv"
  echo "47,100,900,45,60,170,634,19,1828" >> "$csv"

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # Check header.
  [[ "$result" == *"**Task 47: Finalize lock to prevent double-advancing after merge**"* ]]

  # Check table header row.
  [[ "$result" == *"| Phase | Wall | API |"* ]]
  [[ "$result" == *"|-------|------|-----|"* ]]

  # Check each phase row is present.
  [[ "$result" == *"| Coder |"* ]]
  [[ "$result" == *"| Test gate |"* ]]
  [[ "$result" == *"| Fixer |"* ]]
  [[ "$result" == *"| Review |"* ]]
  [[ "$result" == *"| Merger |"* ]]
  [[ "$result" == *"| **Total** |"* ]]
}

# === Table with missing fixer (clean review) ===

@test "build_performance_summary without fixer shows coder and merger only" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"

  # Only coder and merger — clean review skipped the fixer.
  _create_agent_json "${logs}/coder-task-47.json" 600000 200000 30 50 10000 2000000 50000 2.00
  _create_agent_json "${logs}/merger-task-47.json" 15000 15000 1 2 500 10000 0 0.08

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # Should have Coder and Merger but NOT Fixer, Test gate, or Review.
  [[ "$result" == *"| Coder |"* ]]
  [[ "$result" == *"| Merger |"* ]]
  [[ "$result" != *"| Fixer |"* ]]
  [[ "$result" != *"| Test gate |"* ]]
  [[ "$result" != *"| Review |"* ]]
  [[ "$result" == *"| **Total** |"* ]]
}

# === Total row accumulation ===

@test "build_performance_summary totals are accumulated correctly" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 500 0 0 1.00
  _create_agent_json "${logs}/merger-task-47.json" 50000 40000 5 50 200 0 0 0.50

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # Total wall = (100000+50000)/1000 = 150s = 2m30s
  [[ "$result" == *"| **Total** | **2m30s** |"* ]]
  # Total turns = 15
  [[ "$result" == *"| **15** |"* ]]
}

# === gh failure is non-fatal ===

@test "post_performance_summary handles gh failure gracefully" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 500 0 0 1.00

  # Set up git remote for get_repo_slug.
  mkdir -p "$TEST_PROJECT_DIR/.git"
  git -C "$TEST_PROJECT_DIR" init -q -b main
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"
  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/owner/repo.git" 2>/dev/null || true

  # Mock gh to fail.
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"

  # Should not fail — just logs a warning.
  run post_performance_summary "$TEST_PROJECT_DIR" "47" "100"
  [ "$status" -eq 0 ]

  # Check warning was logged.
  grep -q "PERF_SUMMARY.*non-fatal" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

# === Background execution doesn't block ===

@test "post_performance_summary_bg returns immediately" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 500 0 0 1.00

  # Mock gh to succeed after a delay (simulating slow network).
  cat > "$TEST_MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
sleep 5
exit 0
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"

  # Set up git remote.
  mkdir -p "$TEST_PROJECT_DIR/.git"
  git -C "$TEST_PROJECT_DIR" init -q -b main
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"
  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/owner/repo.git" 2>/dev/null || true

  # Measure time — should return in under 2 seconds.
  local start_time
  start_time="$(date +%s)"

  post_performance_summary_bg "$TEST_PROJECT_DIR" "47" "100"

  local end_time
  end_time="$(date +%s)"
  local elapsed=$(( end_time - start_time ))

  # Background call should return near-instantly (< 2s).
  [ "$elapsed" -lt 2 ]

  # Check log confirms background spawn.
  grep -q "PERF_SUMMARY: spawned background post" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

# === Reviewer aggregation ===

@test "aggregate_reviewer_data combines multiple reviewer files" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/reviewer-security-task-47.json" 100000 100000 3 150 2000 50000 10000 0.30
  _create_agent_json "${logs}/reviewer-quality-task-47.json" 70000 70000 2 100 1685 20020 3784 0.25

  local result
  result="$(_aggregate_reviewer_data "$logs" "47")"
  # wall=170000, api=170000, turns=5, in=250, out=3685, cr=70020, cc=13784
  local wall api turns in_tok out_tok cr cc cost
  IFS='|' read -r wall api turns in_tok out_tok cr cc cost <<< "$result"
  [ "$wall" -eq 170000 ]
  [ "$turns" -eq 5 ]
  [ "$in_tok" -eq 250 ]
  [ "$out_tok" -eq 3685 ]
}

@test "aggregate_reviewer_data returns failure with no files" {
  run _aggregate_reviewer_data "${TEST_PROJECT_DIR}/.autopilot/logs" "47"
  [ "$status" -ne 0 ]
}

# === Retries column ===

@test "build_performance_summary shows retry counts" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 500 0 0 1.00

  # Set retry_count=2 and test_fix_retries=1.
  jq '.retry_count = 2 | .test_fix_retries = 1' \
    "$TEST_PROJECT_DIR/.autopilot/state.json" > "$TEST_PROJECT_DIR/.autopilot/state.json.tmp"
  mv "$TEST_PROJECT_DIR/.autopilot/state.json.tmp" "$TEST_PROJECT_DIR/.autopilot/state.json"

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # Coder row should show retries=2.
  local coder_line
  coder_line="$(echo "$result" | grep "| Coder |")"
  [[ "$coder_line" == *"| 2 |"* ]]
}
