#!/usr/bin/env bats
# Tests for lib/live-test-report.sh — validation and report generation.

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/live-test-report.sh"

setup() {
  TEST_DIR="$BATS_TEST_TMPDIR/test_dir"
  mkdir -p "$TEST_DIR"
  RUN_DIR="${TEST_DIR}/run"
  REPO_DIR="${RUN_DIR}/repo"
  AUTOPILOT_DIR="${REPO_DIR}/.autopilot"
  mkdir -p "$AUTOPILOT_DIR"

  # Write a tasks file with 3 tasks.
  cat > "$REPO_DIR/tasks.md" << 'EOF'
## Task 1: Do thing one
Something
## Task 2: Do thing two
Something
## Task 3: Do thing three
Something
EOF

  # Write a start_time (10 minutes ago).
  echo "$(( $(date +%s) - 600 ))" > "${RUN_DIR}/start_time"
}

# --- Test fixtures ---

# Write metrics.csv with all tasks merged.
_fixture_all_merged() {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,merged,11
3,merged,12
EOF
}

# Write a standard token_usage.csv.
_fixture_token_usage() {
  cat > "$AUTOPILOT_DIR/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.05,45000,30000,5
2,implementing,3000,2000,0,0,0.03,30000,20000,3
3,reviewing,1000,500,0,0,0.01,10000,5000,2
EOF
}

# Write a standard phase_timing.csv.
_fixture_phase_timing() {
  cat > "$AUTOPILOT_DIR/phase_timing.csv" << 'EOF'
task_number,phase,start_epoch,duration_ms
1,implementing,1000,60000
2,implementing,2000,90000
3,implementing,3000,45000
EOF
}

# --- _count_report_tasks ---

@test "count_report_tasks returns correct count" {
  local count
  count="$(_count_report_tasks "$REPO_DIR/tasks.md")"
  [ "$count" -eq 3 ]
}

@test "count_report_tasks returns 0 for missing file" {
  local count
  count="$(_count_report_tasks "/nonexistent/tasks.md")"
  [ "$count" -eq 0 ]
}

# --- _count_merged ---

@test "count_merged counts merged rows" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,merged,11
3,in_progress,0
EOF

  local count
  count="$(_count_merged "$AUTOPILOT_DIR/metrics.csv")"
  [ "$count" -eq 2 ]
}

@test "count_merged returns 0 for missing file" {
  local count
  count="$(_count_merged "/nonexistent/metrics.csv")"
  [ "$count" -eq 0 ]
}

@test "count_merged skips header row" {
  # Header has "status" not "merged" — but test explicit NR>1 skipping.
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,merged,pr_number
1,merged,10
EOF
  local count
  count="$(_count_merged "$AUTOPILOT_DIR/metrics.csv")"
  [ "$count" -eq 1 ]
}

# --- _find_failed_tasks ---

@test "find_failed_tasks returns empty when all merged" {
  _fixture_all_merged

  local failed
  failed="$(_find_failed_tasks "$AUTOPILOT_DIR/metrics.csv" 3)"
  [ -z "$failed" ]
}

@test "find_failed_tasks identifies missing tasks" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
3,merged,12
EOF

  local failed
  failed="$(_find_failed_tasks "$AUTOPILOT_DIR/metrics.csv" 3)"
  [[ "$failed" == "2" ]]
}

@test "find_failed_tasks identifies non-merged tasks" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,failed,11
3,in_progress,0
EOF

  local failed
  failed="$(_find_failed_tasks "$AUTOPILOT_DIR/metrics.csv" 3)"
  [[ "$failed" == "2,3" ]]
}

# --- _sum_csv_column ---

@test "sum_csv_column calculates total from token_usage.csv" {
  _fixture_token_usage

  local cost
  cost="$(_sum_csv_column "$AUTOPILOT_DIR/token_usage.csv" 7)"
  [[ "$cost" == "0.0900" ]]
}

@test "sum_csv_column returns 0.0000 for missing file" {
  local cost
  cost="$(_sum_csv_column "/nonexistent/token_usage.csv" 7)"
  [[ "$cost" == "0.0000" ]]
}

@test "sum_csv_column filters by task number" {
  cat > "$AUTOPILOT_DIR/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.05,45000,30000,5
1,reviewing,1000,500,0,0,0.01,10000,5000,2
2,implementing,3000,2000,0,0,0.03,30000,20000,3
EOF

  local cost
  cost="$(_sum_csv_column "$AUTOPILOT_DIR/token_usage.csv" 7 1)"
  [[ "$cost" == "0.0600" ]]
}

# --- _format_duration ---

@test "format_duration formats seconds correctly" {
  local now
  now="$(date +%s)"
  local start=$(( now - 125 ))
  local result
  result="$(_format_duration "$start" "$now")"
  [[ "$result" == "2m 5s" ]]
}

@test "format_duration handles zero elapsed" {
  local now
  now="$(date +%s)"
  local result
  result="$(_format_duration "$now" "$now")"
  [[ "$result" == "0m 0s" ]]
}

@test "format_duration returns unknown for zero start" {
  local result
  result="$(_format_duration 0 100)"
  [[ "$result" == "unknown" ]]
}

@test "format_duration returns unknown when end before start" {
  local result
  result="$(_format_duration 200 100)"
  [[ "$result" == "unknown" ]]
}

# --- _determine_result ---

@test "determine_result returns 0 when all merged" {
  local code
  code="$(_determine_result 0 3 3)"
  [ "$code" -eq 0 ]
}

@test "determine_result returns 1 when some failed" {
  local code
  code="$(_determine_result 0 2 3)"
  [ "$code" -eq 1 ]
}

@test "determine_result returns 2 on timeout" {
  local code
  code="$(_determine_result 2 1 3)"
  [ "$code" -eq 2 ]
}

@test "determine_result returns 3 on setup failure" {
  local code
  code="$(_determine_result 3 0 3)"
  [ "$code" -eq 3 ]
}

@test "determine_result returns 1 when zero tasks" {
  local code
  code="$(_determine_result 0 0 0)"
  [ "$code" -eq 1 ]
}

# --- _result_label ---

@test "result_label shows PASS for code 0" {
  local label
  label="$(_result_label 0 3 3)"
  [[ "$label" == "PASS (3/3 tasks completed)" ]]
}

@test "result_label shows FAIL for code 1" {
  local label
  label="$(_result_label 1 2 3)"
  [[ "$label" == "FAIL (2/3 tasks completed)" ]]
}

@test "result_label shows TIMEOUT for code 2" {
  local label
  label="$(_result_label 2 1 3)"
  [[ "$label" == "TIMEOUT (1/3 tasks completed)" ]]
}

@test "result_label shows SETUP FAILED for code 3" {
  local label
  label="$(_result_label 3 0 3)"
  [[ "$label" == "SETUP FAILED" ]]
}

# --- validate_live_test (all pass) ---

@test "validate_live_test returns 0 when all tasks merged" {
  _fixture_all_merged
  _fixture_phase_timing
  cat > "$AUTOPILOT_DIR/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.02,45000,30000,5
2,implementing,3000,2000,0,0,0.01,30000,20000,3
3,implementing,2000,1000,0,0,0.01,20000,10000,2
EOF

  run validate_live_test "$RUN_DIR" "$REPO_DIR" 0
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/report.md" ]
  [ -f "${RUN_DIR}/summary.txt" ]
}

@test "validate_live_test report contains expected sections" {
  _fixture_all_merged
  cat > "$AUTOPILOT_DIR/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.02,45000,30000,5
EOF

  validate_live_test "$RUN_DIR" "$REPO_DIR" 0

  local report
  report="$(cat "${RUN_DIR}/report.md")"
  [[ "$report" == *"# Autopilot Live Test Report"* ]]
  [[ "$report" == *"**Date:**"* ]]
  [[ "$report" == *"**Duration:**"* ]]
  [[ "$report" == *"**Total cost:**"* ]]
  [[ "$report" == *"**Result:** PASS"* ]]
  [[ "$report" == *"| Task | State |"* ]]
  [[ "$report" == *"## Failures"* ]]
  [[ "$report" == *"None."* ]]
}

# --- validate_live_test (partial failure) ---

@test "validate_live_test returns 1 when some tasks failed" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,failed,11
3,merged,12
EOF

  run validate_live_test "$RUN_DIR" "$REPO_DIR" 0
  [ "$status" -eq 1 ]

  local report
  report="$(cat "${RUN_DIR}/report.md")"
  [[ "$report" == *"FAIL"* ]]
  [[ "$report" == *"Task 2"* ]]
}

# --- validate_live_test (timeout) ---

@test "validate_live_test returns 2 on timeout" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
EOF

  run validate_live_test "$RUN_DIR" "$REPO_DIR" 2
  [ "$status" -eq 2 ]

  local report
  report="$(cat "${RUN_DIR}/report.md")"
  [[ "$report" == *"TIMEOUT"* ]]
}

# --- validate_live_test (setup failure) ---

@test "validate_live_test returns 3 on setup failure" {
  run validate_live_test "$RUN_DIR" "$REPO_DIR" 3
  [ "$status" -eq 3 ]

  local report
  report="$(cat "${RUN_DIR}/report.md")"
  [[ "$report" == *"SETUP FAILED"* ]]
}

# --- summary file ---

@test "summary contains result and cost" {
  _fixture_all_merged
  _fixture_token_usage

  validate_live_test "$RUN_DIR" "$REPO_DIR" 0

  local summary
  summary="$(cat "${RUN_DIR}/summary.txt")"
  [[ "$summary" == *"Result: PASS"* ]]
  [[ "$summary" == *"Tasks: 3/3 merged"* ]]
  [[ "$summary" == *"Cost:"* ]]
}

# --- _task_row ---

@test "task_row builds correct table row" {
  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
EOF
  cat > "$AUTOPILOT_DIR/phase_timing.csv" << 'EOF'
task_number,phase,start_epoch,duration_ms
1,implementing,1000,120000
EOF
  cat > "$AUTOPILOT_DIR/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.05,45000,30000,5
EOF

  local row
  row="$(_task_row 1 "$AUTOPILOT_DIR/metrics.csv" \
    "$AUTOPILOT_DIR/phase_timing.csv" "$AUTOPILOT_DIR/token_usage.csv")"
  [[ "$row" == *"| 1 |"* ]]
  [[ "$row" == *"merged"* ]]
  [[ "$row" == *"#10"* ]]
  [[ "$row" == *'$0.0500'* ]]
}

# --- dynamic task count (not hardcoded) ---

@test "validate_live_test uses dynamic task count from tasks file" {
  # Override with 2 tasks instead of 3.
  cat > "$REPO_DIR/tasks.md" << 'EOF'
## Task 1: Do thing one
Something
## Task 2: Do thing two
Something
EOF

  cat > "$AUTOPILOT_DIR/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,merged,11
EOF

  run validate_live_test "$RUN_DIR" "$REPO_DIR" 0
  [ "$status" -eq 0 ]

  local report
  report="$(cat "${RUN_DIR}/report.md")"
  [[ "$report" == *"PASS (2/2 tasks completed)"* ]]
}
