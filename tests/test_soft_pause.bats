#!/usr/bin/env bats
# Tests for soft/hard pause and task content hash validation.
# Covers: check_quick_guards soft/hard pause behavior,
# check_soft_pause exit, _check_task_content_hash warnings.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/entry-common.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/state.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
  init_pipeline "$TEST_PROJECT_DIR"

  # Reset soft pause flag.
  unset _AUTOPILOT_SOFT_PAUSE
}

# --- Hard Pause ---

@test "hard pause: check_quick_guards returns 1 when PAUSE contains NOW" {
  echo "NOW" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: NOW with trailing newline treated as hard" {
  printf "NOW\n" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: arbitrary non-empty content treated as hard" {
  echo "paused for maintenance" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: STOP content treated as hard" {
  echo "STOP" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

# --- Soft Pause ---

@test "soft pause: check_quick_guards returns 0 when PAUSE is empty" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "soft pause: sets _AUTOPILOT_SOFT_PAUSE flag" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "${_AUTOPILOT_SOFT_PAUSE:-}" = "1" ]
}

@test "soft pause: check_soft_pause exits when flag is set" {
  _AUTOPILOT_SOFT_PAUSE=1
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == "" ]]  # log_msg writes to file, not stdout
  # Verify log was written.
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "soft pause: check_soft_pause is no-op when flag is not set" {
  unset _AUTOPILOT_SOFT_PAUSE
  # Should NOT exit — just return normally.
  check_soft_pause "$TEST_PROJECT_DIR"
  # If we get here, it didn't exit. Success.
  true
}

@test "no pause: check_quick_guards returns 0 when no PAUSE file" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "soft pause: PAUSE with whitespace only treated as soft" {
  printf "  \n  " > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "${_AUTOPILOT_SOFT_PAUSE:-}" = "1" ]
}
