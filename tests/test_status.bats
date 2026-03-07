#!/usr/bin/env bats
# Tests for bin/autopilot-status — pipeline health checker.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/logs"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"

  # Write a minimal state.json.
  cat > "${TEST_PROJECT_DIR}/.autopilot/state.json" <<'EOF'
{"status":"pending","current_task":3,"retry_count":0,"test_fix_retries":0}
EOF

  # Write a minimal tasks.md.
  cat > "${TEST_PROJECT_DIR}/tasks.md" <<'EOF'
# Tasks

## Task 1: First task
Do something.

---

## Task 2: Second task
Do another thing.

---

## Task 3: Third task
Do a third thing.

---

## Task 4: Fourth task
Do a fourth thing.
EOF

  # Unset all AUTOPILOT_* env vars.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset double-source guards so we can re-source in each test.
  unset _AUTOPILOT_CONFIG_LOADED
  unset _AUTOPILOT_STATE_LOADED
  unset _AUTOPILOT_TASKS_LOADED
  unset _AUTOPILOT_ENTRY_COMMON_LOADED
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# Helper: path to the status script.
_status_cmd() {
  echo "$BATS_TEST_DIRNAME/../bin/autopilot-status"
}

@test "status: shows state.json fields" {
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pending"* ]]
  [[ "$output" == *"Current task"* ]]
  [[ "$output" == *"3"* ]]
}

@test "status: shows tasks file info" {
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tasks.md"* ]]
  [[ "$output" == *"Total tasks"* ]]
  [[ "$output" == *"4"* ]]
  [[ "$output" == *"Remaining tasks"* ]]
  [[ "$output" == *"2"* ]]
}

@test "status: shows PAUSED when PAUSE file exists" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PAUSED"* ]]
}

@test "status: shows Not paused when no PAUSE file" {
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not paused"* ]]
}

@test "status: --unpause removes PAUSE file" {
  touch "${TEST_PROJECT_DIR}/.autopilot/PAUSE"
  [ -f "${TEST_PROJECT_DIR}/.autopilot/PAUSE" ]
  run "$(_status_cmd)" --unpause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed (pipeline unpaused)"* ]]
  [ ! -f "${TEST_PROJECT_DIR}/.autopilot/PAUSE" ]
}

@test "status: shows config info when autopilot.conf exists" {
  cat > "${TEST_PROJECT_DIR}/autopilot.conf" <<'EOF'
AUTOPILOT_REPO=test/my-repo
EOF
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot.conf exists"* ]]
  [[ "$output" == *"test/my-repo"* ]]
}

@test "status: shows no active locks when locks dir is empty" {
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active locks"* ]]
}

@test "status: detects stale lock files" {
  echo "99999999" > "${TEST_PROJECT_DIR}/.autopilot/locks/pipeline.lock"
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale"* ]]
}

@test "status: shows summary section" {
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Summary"* ]]
}

@test "status: shows failure when state.json missing" {
  rm -f "${TEST_PROJECT_DIR}/.autopilot/state.json"
  run "$(_status_cmd)" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"File not found"* ]]
  [[ "$output" == *"Pipeline has issues"* ]]
}

@test "status: --help shows usage" {
  run "$(_status_cmd)" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--unpause"* ]]
}
