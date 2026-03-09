#!/usr/bin/env bats
# Tests for bin/autopilot-live-test and lib/live-test-run.sh.

setup() {
  TEST_DIR="$(mktemp -d)"
  export LIVE_TEST_BASE_DIR="${TEST_DIR}/.autopilot/live-test"
  ENTRY_POINT="$BATS_TEST_DIRNAME/../bin/autopilot-live-test"
  LIB_DIR="$BATS_TEST_DIRNAME/../lib"

  # Source orchestration module for unit-testing individual functions.
  source "$LIB_DIR/live-test-run.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- Entry point argument parsing ---

@test "entry point shows usage with --help" {
  run "$ENTRY_POINT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "entry point shows usage with -h" {
  run "$ENTRY_POINT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "entry point fails with no subcommand" {
  run "$ENTRY_POINT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "entry point fails with unknown subcommand" {
  run "$ENTRY_POINT" foobar
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "entry point rejects unknown flags for run" {
  run "$ENTRY_POINT" run --foobar
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

# --- Directory structure ---

@test "run creates expected directory structure" {
  _create_run_dir "${LIVE_TEST_BASE_DIR}/run-test" "${LIVE_TEST_BASE_DIR}/run-test/repo"
  [ -d "${LIVE_TEST_BASE_DIR}/run-test" ]
  [ -d "${LIVE_TEST_BASE_DIR}/run-test/repo" ]
  [ -d "${LIVE_TEST_BASE_DIR}/latest" ]
}

@test "init_test_repo scaffolds and creates git repo" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  _init_test_repo "$repo_dir"
  [ -d "$repo_dir/.git" ]
  [ -f "$repo_dir/src/mathlib.py" ]

  # Verify initial commit exists.
  local commit_count
  commit_count="$(cd "$repo_dir" && git rev-list --count HEAD)"
  [ "$commit_count" -eq 1 ]
}

# --- Config setup ---

@test "write_test_config copies config and tasks" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  _write_test_config "$repo_dir" "$LIB_DIR" 0 "20260309-120000"

  [ -f "$repo_dir/autopilot.conf" ]
  [ -f "$repo_dir/tasks.md" ]
  grep -q "AUTOPILOT_TASKS_FILE=tasks.md" "$repo_dir/autopilot.conf"
}

@test "write_test_config sets branch prefix in github mode" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  _write_test_config "$repo_dir" "$LIB_DIR" 1 "20260309-120000"

  grep -q "AUTOPILOT_BRANCH_PREFIX=live-20260309-120000" "$repo_dir/autopilot.conf"
  grep -q "AUTOPILOT_TARGET_BRANCH=main" "$repo_dir/autopilot.conf"
}

@test "write_test_config disables worktrees" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  _write_test_config "$repo_dir" "$LIB_DIR" 0 "20260309-120000"

  grep -q "AUTOPILOT_USE_WORKTREES=false" "$repo_dir/autopilot.conf"
}

# --- Task counting ---

@test "count_tasks returns correct count from tasks file" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  cat > "$repo_dir/tasks.md" << 'EOF'
## Task 1: Do thing one
Something
## Task 2: Do thing two
Something
## Task 3: Do thing three
Something
EOF

  local count
  count="$(_count_tasks "$repo_dir")"
  [ "$count" -eq 3 ]
}

@test "count_tasks returns 0 when no tasks file" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  local count
  count="$(_count_tasks "$repo_dir")"
  [ "$count" -eq 0 ]
}

# --- Completion detection ---

@test "all_tasks_completed returns false without metrics.csv" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir"
  cat > "$repo_dir/tasks.md" << 'EOF'
## Task 1: Do thing
EOF

  run _all_tasks_completed "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "all_tasks_completed returns false with partial completion" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir/.autopilot"
  cat > "$repo_dir/tasks.md" << 'EOF'
## Task 1: Do thing one
## Task 2: Do thing two
EOF
  cat > "$repo_dir/.autopilot/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
EOF

  run _all_tasks_completed "$repo_dir"
  [ "$status" -eq 1 ]
}

@test "all_tasks_completed returns true when all merged" {
  local repo_dir="${TEST_DIR}/repo"
  mkdir -p "$repo_dir/.autopilot"
  cat > "$repo_dir/tasks.md" << 'EOF'
## Task 1: Do thing one
## Task 2: Do thing two
EOF
  cat > "$repo_dir/.autopilot/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,merged,11
EOF

  run _all_tasks_completed "$repo_dir"
  [ "$status" -eq 0 ]
}

# --- Status display ---

@test "status reports no runs when directory missing" {
  run live_test_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No live test runs found"* ]]
}

@test "status shows finished run details" {
  local run_dir="${LIVE_TEST_BASE_DIR}/run-20260309-120000"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "${LIVE_TEST_BASE_DIR}/current"

  echo "20260309-120000" > "${run_dir}/timestamp"
  echo "99999" > "${run_dir}/pid"
  echo "0" > "${run_dir}/exit_code"
  echo "$(( $(date +%s) - 600 ))" > "${run_dir}/start_time"

  run live_test_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run: 20260309-120000"* ]]
  [[ "$output" == *"finished"* ]]
  [[ "$output" == *"SUCCESS"* ]]
}

@test "status shows timeout result" {
  local run_dir="${LIVE_TEST_BASE_DIR}/run-20260309-120000"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "${LIVE_TEST_BASE_DIR}/current"

  echo "20260309-120000" > "${run_dir}/timestamp"
  echo "99999" > "${run_dir}/pid"
  echo "2" > "${run_dir}/exit_code"
  echo "$(date +%s)" > "${run_dir}/start_time"

  run live_test_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIMEOUT"* ]]
}

@test "status falls back to latest when no current" {
  mkdir -p "${LIVE_TEST_BASE_DIR}/latest"
  echo "20260309-100000" > "${LIVE_TEST_BASE_DIR}/latest/timestamp"
  echo "88888" > "${LIVE_TEST_BASE_DIR}/latest/pid"
  echo "0" > "${LIVE_TEST_BASE_DIR}/latest/exit_code"
  echo "$(date +%s)" > "${LIVE_TEST_BASE_DIR}/latest/start_time"

  run live_test_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run: 20260309-100000"* ]]
}

# --- Clean subcommand ---

@test "clean removes live test artifacts" {
  mkdir -p "${LIVE_TEST_BASE_DIR}/run-test/repo"
  echo "test" > "${LIVE_TEST_BASE_DIR}/run-test/output.log"

  run live_test_clean
  [ "$status" -eq 0 ]
  [ ! -d "$LIVE_TEST_BASE_DIR" ]
  [[ "$output" == *"removed"* ]]
}

@test "clean reports when no artifacts exist" {
  run live_test_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"No live test artifacts"* ]]
}

# --- Artifact copying ---

@test "copy_artifacts saves key files to latest" {
  local run_dir="${LIVE_TEST_BASE_DIR}/run-test"
  local repo_dir="${run_dir}/repo"
  mkdir -p "$repo_dir/.autopilot"
  mkdir -p "${LIVE_TEST_BASE_DIR}/latest"

  echo "0" > "${run_dir}/exit_code"
  echo "test log" > "${run_dir}/output.log"
  echo "12345" > "${run_dir}/pid"
  echo "report content" > "${repo_dir}/.autopilot/report.md"
  echo "task,status" > "${repo_dir}/.autopilot/metrics.csv"

  _copy_artifacts "$run_dir" "$repo_dir"

  [ -f "${LIVE_TEST_BASE_DIR}/latest/exit_code" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/output.log" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/report.md" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/metrics.csv" ]
}

# --- Background PID saving ---

@test "start_background saves PID file" {
  local run_dir="${LIVE_TEST_BASE_DIR}/run-test"
  local repo_dir="${run_dir}/repo"
  mkdir -p "$repo_dir"
  mkdir -p "${LIVE_TEST_BASE_DIR}/latest"

  # Create mock dispatch/review that just exit.
  local mock_dir="${TEST_DIR}/mock-bin"
  mkdir -p "$mock_dir"
  echo '#!/usr/bin/env bash' > "$mock_dir/autopilot-dispatch"
  echo 'exit 0' >> "$mock_dir/autopilot-dispatch"
  chmod +x "$mock_dir/autopilot-dispatch"
  cp "$mock_dir/autopilot-dispatch" "$mock_dir/autopilot-review"

  export PATH="${mock_dir}:${PATH}"

  # Create a tasks file so _all_tasks_completed has something to check.
  echo "## Task 1: test" > "$repo_dir/tasks.md"
  # Create metrics.csv so all tasks appear merged (loop exits immediately).
  mkdir -p "$repo_dir/.autopilot"
  printf 'task_number,status\n1,merged,1\n' > "$repo_dir/.autopilot/metrics.csv"

  _start_background "$run_dir" "$repo_dir" "$LIB_DIR" 0

  [ -f "${run_dir}/pid" ]
  local pid
  pid="$(cat "${run_dir}/pid")"
  [[ "$pid" =~ ^[0-9]+$ ]]

  # Wait for background process to finish.
  wait "$pid" 2>/dev/null || true

  # Exit code should be written.
  [ -f "${run_dir}/exit_code" ]
}

# --- Global timeout constant ---

@test "global timeout is 3600 seconds" {
  [ "$LIVE_TEST_TIMEOUT_SECONDS" -eq 3600 ]
}

@test "tick interval is 15 seconds" {
  [ "$LIVE_TEST_TICK_INTERVAL" -eq 15 ]
}

# --- Cost estimate display ---

@test "show_cost_estimate displays total from token_usage.csv" {
  local status_dir="${TEST_DIR}/status"
  mkdir -p "$status_dir"
  cat > "$status_dir/token_usage.csv" << 'EOF'
task_number,phase,input_tokens,output_tokens,cache_read,cache_create,cost_usd,wall_ms,api_ms,num_turns
1,implementing,5000,3000,0,0,0.05,45000,30000,5
2,implementing,3000,2000,0,0,0.03,30000,20000,3
EOF

  run _show_cost_estimate "$status_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$0.0800'* ]]
}
