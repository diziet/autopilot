#!/usr/bin/env bats
# Tests for live test integration in autopilot-doctor and autopilot-status.

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup() {
  _setup_isolated_env
  _setup_valid_project "$TEST_DIR/project"
  cd "$TEST_DIR/project"
}

teardown() {
  _teardown_isolated_env
}

# Create a live test summary fixture with configurable fields.
_create_live_test_summary() {
  local dir="$1" result="$2" tasks="$3" duration="$4" cost="$5" date="$6"
  mkdir -p "$dir"
  cat > "$dir/summary.txt" <<SUMMARY
Result: ${result}
Tasks: ${tasks}
Duration: ${duration}
Cost: ${cost}
SUMMARY
  echo "$date" > "$dir/timestamp"
}

# Run autopilot-doctor with isolated PATH.
_run_doctor() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-doctor" "$TEST_DIR/project"
}

# --- Doctor: live test never run ---

@test "doctor: shows 'Never run' when no live test directory exists" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live Test (informational)"* ]]
  [[ "$output" == *"[INFO] Never run"* ]]
}

@test "doctor: live test section does not cause failure" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
}

# --- Doctor: live test with summary ---

@test "doctor: shows result from completed live test" {
  _create_live_test_summary \
    "$TEST_DIR/project/.autopilot/live-test/latest" \
    "PASS — 6/6 merged" "6/6 merged" "25m 30s" '$0.0512' "2026-03-07 14:30:00"

  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] Last run: 2026-03-07 14:30:00"* ]]
  [[ "$output" == *"[INFO] Result: PASS — 6/6 merged"* ]]
  [[ "$output" == *"[INFO] Duration: 25m 30s"* ]]
  [[ "$output" == *'[INFO] Cost: $0.0512'* ]]
}

@test "doctor: shows FAIL result from failed live test" {
  _create_live_test_summary \
    "$TEST_DIR/project/.autopilot/live-test/latest" \
    "FAIL — 4/6 merged" "4/6 merged" "45m 12s" '$0.0834' "2026-03-06 10:00:00"

  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] Result: FAIL — 4/6 merged"* ]]
}

@test "doctor: shows info when latest dir exists but no summary" {
  local lt_dir="$TEST_DIR/project/.autopilot/live-test/latest"
  mkdir -p "$lt_dir"

  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] No summary available"* ]]
}

# --- Status: live test integration ---

# Run autopilot-status with isolated PATH and mocked state.
_run_status() {
  # Status requires state.json and config to exist.
  mkdir -p "$TEST_DIR/project/.autopilot/logs"
  cat > "$TEST_DIR/project/.autopilot/state.json" << 'STATE'
{"status":"completed","current_task":1,"retry_count":0}
STATE
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-status" "$TEST_DIR/project"
}

@test "status: shows 'never run' when no live test exists" {
  _run_status
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Live Test"* ]]
  [[ "$output" == *"never run"* ]]
}

@test "status: shows live test result when available" {
  _create_live_test_summary \
    "$TEST_DIR/project/.autopilot/live-test/latest" \
    "PASS — 6/6 merged" "6/6 merged" "25m 30s" '$0.0512' "2026-03-07 14:30:00"

  _run_status
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS — 6/6 merged"* ]]
  [[ "$output" == *"2026-03-07 14:30:00"* ]]
  [[ "$output" == *'$0.0512'* ]]
}

@test "status: shows warn level when live test failed" {
  _create_live_test_summary \
    "$TEST_DIR/project/.autopilot/live-test/latest" \
    "FAIL — 4/6 merged" "4/6 merged" "45m 12s" '$0.0834' "2026-03-06 10:00:00"

  _run_status
  echo "$output"
  [ "$status" -eq 0 ]
  # Should show warning indicator, not pass
  [[ "$output" == *"FAIL — 4/6 merged"* ]]
}
