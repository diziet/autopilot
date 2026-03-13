#!/usr/bin/env bats
# Tests for live test integration in autopilot-doctor and autopilot-status.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup_file() {
  _create_mock_template

  # Pre-build cached doctor and status runs for common cases.
  local base="${BATS_FILE_TMPDIR}/cached"
  local mock_bin="${base}/mock_bin"
  mkdir -p "$mock_bin" "${base}/home"

  # Copy mocks.
  if [[ -n "${_MOCK_TEMPLATE_DIR:-}" && -d "$_MOCK_TEMPLATE_DIR" ]]; then
    cp "$_MOCK_TEMPLATE_DIR"/* "$mock_bin/" 2>/dev/null || true
  fi

  # --- Doctor: no live test (never run) ---
  local proj_none="${base}/proj_none"
  _setup_valid_project "$proj_none"
  _setup_scheduler_plist "$proj_none" "${base}/home"
  export _DOCTOR_NEVER_RUN_OUTPUT
  _DOCTOR_NEVER_RUN_OUTPUT="$(HOME="${base}/home" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$proj_none" 2>&1)" || true
  export _DOCTOR_NEVER_RUN_STATUS=$?

  # --- Doctor: with passing live test ---
  local proj_pass="${base}/proj_pass"
  _setup_valid_project "$proj_pass"
  _create_live_test_summary \
    "$proj_pass/.autopilot/live-test/latest" \
    "PASS — 6/6 merged" "6/6 merged" "25m 30s" '$0.0512' "2026-03-07 14:30:00"
  _setup_scheduler_plist "$proj_pass" "${base}/home"
  export _DOCTOR_PASS_OUTPUT
  _DOCTOR_PASS_OUTPUT="$(HOME="${base}/home" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$proj_pass" 2>&1)" || true
  export _DOCTOR_PASS_STATUS=$?

  # --- Doctor: with failing live test ---
  local proj_fail="${base}/proj_fail"
  _setup_valid_project "$proj_fail"
  _create_live_test_summary \
    "$proj_fail/.autopilot/live-test/latest" \
    "FAIL — 4/6 merged" "4/6 merged" "45m 12s" '$0.0834' "2026-03-06 10:00:00"
  _setup_scheduler_plist "$proj_fail" "${base}/home"
  export _DOCTOR_FAIL_OUTPUT
  _DOCTOR_FAIL_OUTPUT="$(HOME="${base}/home" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$proj_fail" 2>&1)" || true
  export _DOCTOR_FAIL_STATUS=$?

  # --- Doctor: latest dir exists but no summary ---
  local proj_nosummary="${base}/proj_nosummary"
  _setup_valid_project "$proj_nosummary"
  mkdir -p "$proj_nosummary/.autopilot/live-test/latest"
  _setup_scheduler_plist "$proj_nosummary" "${base}/home"
  export _DOCTOR_NOSUMMARY_OUTPUT
  _DOCTOR_NOSUMMARY_OUTPUT="$(HOME="${base}/home" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$proj_nosummary" 2>&1)" || true
  export _DOCTOR_NOSUMMARY_STATUS=$?
}

teardown_file() {
  _cleanup_mock_template
}

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

# --- Doctor: live test never run (cached) ---

@test "doctor: shows 'Never run' when no live test directory exists" {
  [ "$_DOCTOR_NEVER_RUN_STATUS" -eq 0 ]
  [[ "$_DOCTOR_NEVER_RUN_OUTPUT" == *"Live Test (informational)"* ]]
  [[ "$_DOCTOR_NEVER_RUN_OUTPUT" == *"[INFO] Never run"* ]]
}

@test "doctor: live test section does not cause failure" {
  [ "$_DOCTOR_NEVER_RUN_STATUS" -eq 0 ]
  [[ "$_DOCTOR_NEVER_RUN_OUTPUT" == *"All checks passed"* ]]
}

# --- Doctor: live test with summary (cached) ---

@test "doctor: shows result from completed live test" {
  [ "$_DOCTOR_PASS_STATUS" -eq 0 ]
  [[ "$_DOCTOR_PASS_OUTPUT" == *"[INFO] Last run: 2026-03-07 14:30:00"* ]]
  [[ "$_DOCTOR_PASS_OUTPUT" == *"[INFO] Result: PASS — 6/6 merged"* ]]
  [[ "$_DOCTOR_PASS_OUTPUT" == *"[INFO] Duration: 25m 30s"* ]]
  [[ "$_DOCTOR_PASS_OUTPUT" == *'[INFO] Cost: $0.0512'* ]]
}

@test "doctor: shows FAIL result from failed live test" {
  [ "$_DOCTOR_FAIL_STATUS" -eq 0 ]
  [[ "$_DOCTOR_FAIL_OUTPUT" == *"[INFO] Result: FAIL — 4/6 merged"* ]]
}

@test "doctor: shows info when latest dir exists but no summary" {
  [ "$_DOCTOR_NOSUMMARY_STATUS" -eq 0 ]
  [[ "$_DOCTOR_NOSUMMARY_OUTPUT" == *"[INFO] No summary available"* ]]
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
