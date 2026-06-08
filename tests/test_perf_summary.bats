#!/usr/bin/env bats
# Tests for lib/perf-summary.sh — performance summary table formatting
# and background PR comment posting.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/perf-summary.sh"
source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
source "$BATS_TEST_DIRNAME/../lib/git-pr.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  # Override default state for perf summary tests.
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

# --- Helper to create agent output JSON ---

_create_agent_json() {
  local file="$1" wall_ms="$2" api_ms="$3" turns="$4"
  local in_tok="$5" out_tok="$6" cache_r="$7" cache_c="$8" cost="$9"
  # Optional 10th arg: visible result text (drives the reasoning estimate).
  local result="${10:-}"
  cat > "$file" << JSON
{
  "result": $(printf '%s' "$result" | jq -R -s '.'),
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

  # No .result field, so reasoning (9th field) = full output_tokens.
  local result
  result="$(_extract_agent_row "$json")"
  [ "$result" = "900000|318000|69|71|15528|4436946|69202|3.04|15528" ]
}

@test "extract_agent_row returns empty for missing file" {
  local result
  result="$(_extract_agent_row "/nonexistent/file.json")" || true
  [ -z "$result" ]
}

# === Phase row formatting ===

@test "format_phase_row produces valid markdown row" {
  local result
  result="$(_format_phase_row "Coder" "900000|318000|69|71|15528|4436946|69202|3.04|9000" "0")"
  [[ "$result" == "| Coder |"* ]]
  [[ "$result" == *"| 900s |"* ]]
  [[ "$result" == *"| 318s |"* ]]
  [[ "$result" == *"| 69 |"* ]]
  # Reason (est) column renders the 9th field, formatted with commas.
  [[ "$result" == *"| 9,000 |"* ]]
  [[ "$result" == *'| $3.04 |' ]]
}

@test "format_phase_row rounds cost to two decimal places" {
  # Raw float cost like 1.2961435000000001 should display as $1.30.
  # The trailing 9th field (reasoning) must not be folded into cost.
  local result
  result="$(_format_phase_row "Coder" "900000|318000|69|71|15528|4436946|69202|1.2961435000000001|9000" "0")"
  [[ "$result" == *'| $1.30 |' ]]

  # Already-rounded cost stays the same.
  result="$(_format_phase_row "Fixer" "100000|80000|10|50|500|0|0|3.04|300" "0")"
  [[ "$result" == *'| $3.04 |' ]]

  # Integer cost gets .00 suffix.
  result="$(_format_phase_row "Merger" "10000|5000|1|3|100|0|0|2|80" "0")"
  [[ "$result" == *'| $2.00 |' ]]
}

@test "build_performance_summary formats per-phase costs to two decimals" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"

  # Create agent JSON with a raw floating-point cost.
  _create_agent_json "${logs}/coder-task-47.json" 900000 318000 69 71 15528 4436946 69202 1.2961435000000001

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # Per-phase row should show rounded cost.
  local coder_line
  coder_line="$(echo "$result" | grep "| Coder |")"
  [[ "$coder_line" == *'| $1.30 |' ]]

  # Total row should also be rounded.
  local total_line
  total_line="$(echo "$result" | grep "| \*\*Total\*\* |")"
  [[ "$total_line" == *'$1.30'* ]]
}

@test "format_phase_only_row shows dashes for agent columns" {
  local result
  result="$(_format_phase_only_row "Test gate" "45")"
  [[ "$result" == "| Test gate | 45s |"* ]]
  # Count the dash columns
  local dash_count
  dash_count="$(echo "$result" | grep -o '—' | wc -l | tr -d ' ')"
  [ "$dash_count" -eq 9 ]
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

# === Total row cache token accumulation (Task 186) ===

# Extract the Nth pipe-delimited cell from a markdown row, stripped of
# surrounding spaces and bold (**) markers.
_cell() {
  local line="$1" col="$2"
  echo "$line" | awk -F'|' -v c="$col" '{gsub(/[ *]/,"",$c); print $c}'
}

# Run the summary and return just the bold Total row.
_total_row() {
  build_performance_summary "$1" "$2" | grep "| \*\*Total\*\* |"
}

# Seed coder + merger agent JSON with fixed wall/api/turns/token/cost
# columns, varying only the per-agent cache cells so each test controls the
# totals it asserts. Args: coder_cache_r coder_cache_c merger_cache_r merger_cache_c
_seed_coder_merger() {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 500 "$1" "$2" 1.00
  _create_agent_json "${logs}/merger-task-47.json" 50000 40000 5 50 200 "$3" "$4" 0.50
}

@test "build_performance_summary Total row shows summed cache read" {
  _seed_coder_merger 1000 200 3000 50

  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"

  # Cache Read total = 1000 + 3000 = 4000 (column 9 after Reason est inserted).
  local cache_r
  cache_r="$(_cell "$total_line" 9)"
  [ "$cache_r" != "—" ]
  [ "$cache_r" = "4,000" ]
}

@test "build_performance_summary Total row shows summed cache create" {
  _seed_coder_merger 1000 200 3000 50

  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"

  # Cache Create total = 200 + 50 = 250 (column 10 after Reason est inserted).
  local cache_c
  cache_c="$(_cell "$total_line" 10)"
  [ "$cache_c" != "—" ]
  [ "$cache_c" = "250" ]
}

@test "build_performance_summary Total cache equals sum across all phases" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 900000 318000 69 71 15528 4436946 69202 3.04
  _create_agent_json "${logs}/fixer-task-47.json" 634000 205000 45 83 12340 4412000 1200 3.11
  _create_agent_json "${logs}/reviewer-security-task-47.json" 170000 170000 5 250 3685 70020 13784 0.55
  _create_agent_json "${logs}/merger-task-47.json" 19000 19000 1 3 737 14004 0 0.11

  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"

  # Cache Read = 4436946 + 4412000 + 70020 + 14004 = 8932970 (column 9)
  [ "$(_cell "$total_line" 9)" = "8,932,970" ]
  # Cache Create = 69202 + 1200 + 13784 + 0 = 84186 (column 10)
  [ "$(_cell "$total_line" 10)" = "84,186" ]
}

@test "build_performance_summary Total cache renders 0 not dash when all zero" {
  _seed_coder_merger 0 0 0 0

  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"

  [ "$(_cell "$total_line" 9)" = "0" ]
  [ "$(_cell "$total_line" 10)" = "0" ]
}

@test "build_performance_summary Total non-cache columns unchanged with cache" {
  _seed_coder_merger 1000 200 3000 50

  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"

  # Wall (col 3) = (100000+50000)/1000 = 150s = 2m30s
  [ "$(_cell "$total_line" 3)" = "2m30s" ]
  # API (col 4) stays a dash.
  [ "$(_cell "$total_line" 4)" = "—" ]
  # Turns (col 5) = 10 + 5 = 15
  [ "$(_cell "$total_line" 5)" = "15" ]
  # Tokens In (col 6) = 100 + 50 = 150
  [ "$(_cell "$total_line" 6)" = "150" ]
  # Tokens Out (col 7) = 500 + 200 = 700
  [ "$(_cell "$total_line" 7)" = "700" ]
  # Retries (col 11 after Reason est inserted) = 0
  [ "$(_cell "$total_line" 11)" = "0" ]
  # Cost (col 12 after Reason est inserted) = 1.00 + 0.50 = $1.50
  [ "$(_cell "$total_line" 12)" = '$1.50' ]
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
sleep 0.5
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
  # No .result in the mock JSON, so reasoning (9th field) = out = 3685.
  local wall api turns in_tok out_tok cr cc cost reason
  IFS='|' read -r wall api turns in_tok out_tok cr cc cost reason <<< "$result"
  [ "$wall" -eq 170000 ]
  [ "$turns" -eq 5 ]
  [ "$in_tok" -eq 250 ]
  [ "$out_tok" -eq 3685 ]
  [ "$reason" -eq 3685 ]
}

@test "aggregate_reviewer_data returns failure with no files" {
  run _aggregate_reviewer_data "${TEST_PROJECT_DIR}/.autopilot/logs" "47"
  [ "$status" -ne 0 ]
}

# === Reasoning split (Task 187) ===

@test "build_performance_summary renders Reason (est) column and Total" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  local coder_result merger_result
  coder_result="$(printf 'a%.0s' {1..1000})"
  merger_result="$(printf 'a%.0s' {1..500})"
  _create_agent_json "${logs}/coder-task-47.json" 100000 80000 10 100 2000 0 0 1.00 "$coder_result"
  _create_agent_json "${logs}/merger-task-47.json" 50000 40000 5 50 500 0 0 0.50 "$merger_result"

  local result
  result="$(build_performance_summary "$TEST_PROJECT_DIR" "47")"

  # New column header is present.
  [[ "$result" == *"| Reason (est) |"* ]]

  # Coder reasoning = 2000 - round(0.328*1000=328) = 1672 (col 8).
  local coder_line
  coder_line="$(echo "$result" | grep "| Coder |")"
  [ "$(_cell "$coder_line" 8)" = "1,672" ]

  # Merger reasoning = 500 - round(0.328*500=164) = 336 (col 8).
  local merger_line
  merger_line="$(echo "$result" | grep "| Merger |")"
  [ "$(_cell "$merger_line" 8)" = "336" ]

  # Total reasoning = 1672 + 336 = 2008 (col 8).
  local total_line
  total_line="$(_total_row "$TEST_PROJECT_DIR" "47")"
  [ "$(_cell "$total_line" 8)" = "2,008" ]

  # Tokens Out total is unchanged (purely additive column).
  [ "$(_cell "$total_line" 7)" = "2,500" ]

  # Footnote is present.
  [[ "$result" == *"Reason (est) = output"* ]]
}

@test "build_performance_summary sums reviewer reasoning across personas" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  local r1 r2
  r1="$(printf 'a%.0s' {1..1000})"
  r2="$(printf 'a%.0s' {1..500})"
  _create_agent_json "${logs}/reviewer-security-task-47.json" 100000 100000 3 150 2000 0 0 0.30 "$r1"
  _create_agent_json "${logs}/reviewer-quality-task-47.json" 70000 70000 2 100 1000 0 0 0.25 "$r2"

  local review_line
  review_line="$(build_performance_summary "$TEST_PROJECT_DIR" "47" | grep "| Review |")"
  # security: 2000 - 328 = 1672; quality: 1000 - 164 = 836; sum = 2508 (col 8).
  [ "$(_cell "$review_line" 8)" = "2,508" ]
}

@test "build_performance_summary phase-only row stays column-aligned" {
  local logs="${TEST_PROJECT_DIR}/.autopilot/logs"
  _create_agent_json "${logs}/coder-task-47.json" 900000 318000 69 71 15528 4436946 69202 3.04

  # Phase timing with a test gate (test_fixing_sec > 0).
  local csv="${TEST_PROJECT_DIR}/.autopilot/phase_timing.csv"
  echo "task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,reviewed_sec,fixing_sec,merging_sec,total_sec" > "$csv"
  echo "47,100,900,45,60,170,634,19,1828" >> "$csv"

  local tg_line
  tg_line="$(build_performance_summary "$TEST_PROJECT_DIR" "47" | grep "| Test gate |")"
  # Reason (est) cell (col 8) is a dash for the agentless test-gate row.
  [ "$(_cell "$tg_line" 8)" = "—" ]
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
