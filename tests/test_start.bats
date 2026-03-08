#!/usr/bin/env bats
# Tests for bin/autopilot-start — validate and start the pipeline.

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup() {
  _setup_isolated_env
  _setup_valid_project "$TEST_DIR/project"

  # Create a wrapper for autopilot-doctor that calls the real binary.
  cat > "$MOCK_BIN/autopilot-doctor" << WRAPPER
#!/usr/bin/env bash
exec "$REPO_DIR/bin/autopilot-doctor" "\$@"
WRAPPER
  chmod +x "$MOCK_BIN/autopilot-doctor"

  # Create PAUSE file (pipeline is paused by default).
  mkdir -p "$TEST_DIR/project/.autopilot"
  touch "$TEST_DIR/project/.autopilot/PAUSE"
}

teardown() {
  _teardown_isolated_env
}

# Run autopilot-start with isolated PATH.
_run_start() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-start" "$TEST_DIR/project"
}

# --- Start removes PAUSE after doctor passes ---

@test "start: removes PAUSE file when doctor passes" {
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  _run_start
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Pipeline started"* ]]
  [[ "$output" == *"tail -f .autopilot/logs/pipeline.log"* ]]
}

@test "start: creates logs directory on success" {
  _run_start
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/project/.autopilot/logs" ]
}

# --- Start aborts when doctor fails ---

@test "start: aborts when doctor fails (missing config)" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_start
  echo "$output"
  [ "$status" -eq 1 ]
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Start aborted"* ]]
}

@test "start: aborts when doctor fails (missing tasks)" {
  rm -f "$TEST_DIR/project/tasks.md"
  _run_start
  echo "$output"
  [ "$status" -eq 1 ]
  [ -f "$TEST_DIR/project/.autopilot/PAUSE" ]
  [[ "$output" == *"Start aborted"* ]]
}

# --- Idempotent when already running ---

@test "start: prints already running when no PAUSE file" {
  rm -f "$TEST_DIR/project/.autopilot/PAUSE"
  _run_start
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipeline is already running."* ]]
}

# --- Always validates even when already running ---

@test "start: runs doctor even when already unpaused" {
  rm -f "$TEST_DIR/project/.autopilot/PAUSE"
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_start
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Start aborted"* ]]
}

# --- No .autopilot directory at all ---

@test "start: runs doctor when .autopilot dir does not exist" {
  rm -rf "$TEST_DIR/project/.autopilot"
  _run_start
  echo "$output"
  # Doctor passes, no PAUSE file => already running message
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipeline is already running."* ]]
}

# --- Help flag ---

@test "start: --help prints usage" {
  run "$REPO_DIR/bin/autopilot-start" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"autopilot-start"* ]]
}

# --- Unknown option ---

@test "start: rejects unknown options" {
  run "$REPO_DIR/bin/autopilot-start" --bogus
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

# --- Invalid project directory ---

@test "start: fails for nonexistent project directory" {
  run "$REPO_DIR/bin/autopilot-start" "/tmp/nonexistent-dir-xyz"
  echo "$output"
  [ "$status" -ne 0 ]
}
