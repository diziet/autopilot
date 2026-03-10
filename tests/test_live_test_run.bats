#!/usr/bin/env bats
# Tests for bin/autopilot-live-test and lib/live-test-run.sh.

setup() {
  TEST_DIR="$BATS_TEST_TMPDIR/test_dir"
  mkdir -p "$TEST_DIR"
  REPO_DIR="${TEST_DIR}/repo"
  mkdir -p "$REPO_DIR"
  export LIVE_TEST_BASE_DIR="${TEST_DIR}/.autopilot/live-test"
  ENTRY_POINT="$BATS_TEST_DIRNAME/../bin/autopilot-live-test"
  LIB_DIR="$BATS_TEST_DIRNAME/../lib"

  # Source per-test: live-test-run.sh sets LIVE_TEST_BASE_DIR as readonly,
  # so it must be sourced after each test's LIVE_TEST_BASE_DIR is exported.
  source "$LIB_DIR/live-test-run.sh"
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

@test "entry point rejects --github for status subcommand" {
  run "$ENTRY_POINT" status --github
  [ "$status" -eq 1 ]
  [[ "$output" == *"only valid for the 'run' subcommand"* ]]
}

@test "entry point rejects --keep for clean subcommand" {
  run "$ENTRY_POINT" clean --keep
  [ "$status" -eq 1 ]
  [[ "$output" == *"only valid for the 'run' subcommand"* ]]
}

# --- Directory structure ---

@test "init_test_repo scaffolds and creates git repo" {
  _init_test_repo "$REPO_DIR"
  [ -d "$REPO_DIR/.git" ]
  [ -f "$REPO_DIR/src/mathlib.py" ]

  # Verify initial commit exists.
  local commit_count
  commit_count="$(cd "$REPO_DIR" && git rev-list --count HEAD)"
  [ "$commit_count" -eq 1 ]
}

# --- Config setup ---

@test "write_test_config copies config and tasks" {
  _write_test_config "$REPO_DIR" "$LIB_DIR" 0 "20260309-120000"

  [ -f "$REPO_DIR/autopilot.conf" ]
  [ -f "$REPO_DIR/tasks.md" ]
  grep -q "AUTOPILOT_TASKS_FILE=tasks.md" "$REPO_DIR/autopilot.conf"
}

@test "write_test_config sets branch prefix in github mode" {
  _write_test_config "$REPO_DIR" "$LIB_DIR" 1 "20260309-120000"

  grep -q "AUTOPILOT_BRANCH_PREFIX=live-20260309-120000" "$REPO_DIR/autopilot.conf"
  grep -q "AUTOPILOT_TARGET_BRANCH=main" "$REPO_DIR/autopilot.conf"
}

@test "write_test_config disables worktrees" {
  _write_test_config "$REPO_DIR" "$LIB_DIR" 0 "20260309-120000"

  grep -q "AUTOPILOT_USE_WORKTREES=false" "$REPO_DIR/autopilot.conf"
}

# --- Task counting ---

@test "count_tasks returns correct count from tasks file" {
  cat > "$REPO_DIR/tasks.md" << 'EOF'
## Task 1: Do thing one
Something
## Task 2: Do thing two
Something
## Task 3: Do thing three
Something
EOF

  local count
  count="$(_count_tasks "$REPO_DIR")"
  [ "$count" -eq 3 ]
}

@test "count_tasks returns 0 when no tasks file" {
  local empty_dir="${TEST_DIR}/empty"
  mkdir -p "$empty_dir"
  local count
  count="$(_count_tasks "$empty_dir")"
  [ "$count" -eq 0 ]
}

@test "count_tasks returns 0 when tasks file has no matching headings" {
  echo "# Just a header" > "$REPO_DIR/tasks.md"
  local count
  count="$(_count_tasks "$REPO_DIR")"
  [ "$count" -eq 0 ]
}

# --- Completion detection ---

@test "all_tasks_completed returns false without metrics.csv" {
  echo "## Task 1: Do thing" > "$REPO_DIR/tasks.md"

  run _all_tasks_completed "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "all_tasks_completed returns false with partial completion" {
  mkdir -p "$REPO_DIR/.autopilot"
  cat > "$REPO_DIR/tasks.md" << 'EOF'
## Task 1: Do thing one
## Task 2: Do thing two
EOF
  cat > "$REPO_DIR/.autopilot/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
EOF

  run _all_tasks_completed "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "all_tasks_completed returns true when all merged" {
  mkdir -p "$REPO_DIR/.autopilot"
  cat > "$REPO_DIR/tasks.md" << 'EOF'
## Task 1: Do thing one
## Task 2: Do thing two
EOF
  cat > "$REPO_DIR/.autopilot/metrics.csv" << 'EOF'
task_number,status,pr_number
1,merged,10
2,merged,11
EOF

  run _all_tasks_completed "$REPO_DIR"
  [ "$status" -eq 0 ]
}

@test "all_tasks_completed does not match substring of merged" {
  mkdir -p "$REPO_DIR/.autopilot"
  echo "## Task 1: Do thing" > "$REPO_DIR/tasks.md"
  cat > "$REPO_DIR/.autopilot/metrics.csv" << 'EOF'
task_number,status,pr_number
1,unmerged,10
EOF

  run _all_tasks_completed "$REPO_DIR"
  [ "$status" -eq 1 ]
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

  echo "0" > "${run_dir}/exit_code"
  echo "test log" > "${run_dir}/output.log"
  echo "12345" > "${run_dir}/pid"
  echo "report content" > "${run_dir}/report.md"
  echo "task,status" > "${repo_dir}/.autopilot/metrics.csv"

  _copy_artifacts "$run_dir" "$repo_dir"

  [ -f "${LIVE_TEST_BASE_DIR}/latest/exit_code" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/output.log" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/report.md" ]
  [ -f "${LIVE_TEST_BASE_DIR}/latest/metrics.csv" ]
}

# --- copy_if_exists helper ---

@test "copy_if_exists copies existing files and skips missing" {
  local src="${TEST_DIR}/src"
  local dest="${TEST_DIR}/dest"
  mkdir -p "$src" "$dest"
  echo "a" > "$src/exists.txt"

  _copy_if_exists "$src" "$dest" exists.txt missing.txt

  [ -f "$dest/exists.txt" ]
  [ ! -f "$dest/missing.txt" ]
}

# --- resolve_artifact_path helper ---

@test "resolve_artifact_path prefers repo dir when present" {
  local status_dir="${TEST_DIR}/status"
  mkdir -p "${status_dir}/repo"

  local path
  path="$(_resolve_artifact_path "$status_dir" "metrics.csv")"
  [[ "$path" == *"/repo/.autopilot/metrics.csv" ]]
}

@test "resolve_artifact_path falls back to flat dir" {
  local status_dir="${TEST_DIR}/status"
  mkdir -p "$status_dir"

  local path
  path="$(_resolve_artifact_path "$status_dir" "metrics.csv")"
  [[ "$path" == "${status_dir}/metrics.csv" ]]
}

# --- GitHub org validation ---

@test "setup_github_remote validates LIVE_TEST_GITHUB_ORG is set" {
  # LIVE_TEST_GITHUB_ORG is readonly="diziet" from live-test.sh.
  # Verify the validation guard exists by checking the function source.
  local func_body
  func_body="$(declare -f _setup_github_remote)"
  [[ "$func_body" == *'LIVE_TEST_GITHUB_ORG'* ]]
  [[ "$func_body" == *'is not set'* ]]
}

# --- Background PID saving ---

@test "start_background saves PID file" {
  local run_dir="${LIVE_TEST_BASE_DIR}/run-test"
  local repo_dir="${run_dir}/repo"
  mkdir -p "$repo_dir"

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

@test "start_background returns 1 when binaries not found" {
  run _start_background "${TEST_DIR}/run" "$REPO_DIR" "/nonexistent" 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot find"* ]]
}

# --- Global timeout constant ---

@test "global timeout is 3600 seconds" {
  [ "$LIVE_TEST_TIMEOUT_SECONDS" -eq 3600 ]
}

@test "tick interval is 15 seconds" {
  [ "$LIVE_TEST_TICK_INTERVAL" -eq 15 ]
}

@test "max consecutive failures is 10" {
  [ "$_LIVE_TEST_MAX_CONSECUTIVE_FAILURES" -eq 10 ]
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
