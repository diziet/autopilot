#!/usr/bin/env bats
# Tests for lock management in lib/state.sh.

load helpers/test_template

# Source libs once at file level (not per-test).
source "$BATS_TEST_DIRNAME/../lib/state.sh"

setup() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  mkdir -p "$TEST_PROJECT_DIR"

  _unset_autopilot_vars
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  : # BATS_TEST_TMPDIR is auto-cleaned
}

# --- acquire_lock ---

@test "acquire_lock creates lock file with current PID" {
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]
}

@test "acquire_lock returns 0 on success" {
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "acquire_lock returns 1 when lock already held by live process" {
  # Create a lock owned by a live process (init, PID 1)
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "acquire_lock defaults to pipeline lock name" {
  acquire_lock "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

@test "acquire_lock supports custom lock names" {
  acquire_lock "$TEST_PROJECT_DIR" "reviewer"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/reviewer.lock" ]
}

@test "acquire_lock creates locks directory if missing" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot/locks"
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

@test "acquire_lock removes stale lock from dead PID" {
  # Use a PID that almost certainly doesn't exist
  echo "99999999" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
  local pid
  pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock")"
  [ "$pid" = "$$" ]
}

@test "acquire_lock logs warning when removing stale lock" {
  echo "99999999" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"stale lock"* ]]
}

# --- release_lock ---

@test "release_lock removes lock file we own" {
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

@test "release_lock returns 0 when lock file does not exist" {
  run release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "release_lock returns 1 when lock owned by another PID" {
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"
  run release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
  # Lock file should still exist
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

@test "release_lock logs warning when refusing to release" {
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"
  release_lock "$TEST_PROJECT_DIR" "pipeline" 2>/dev/null || true
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"Cannot release lock"* ]]
}

@test "release_lock defaults to pipeline lock name" {
  acquire_lock "$TEST_PROJECT_DIR"
  release_lock "$TEST_PROJECT_DIR"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
}

# --- _is_lock_stale ---

@test "_is_lock_stale returns 0 for empty PID" {
  run _is_lock_stale "$TEST_PROJECT_DIR" "/nonexistent" ""
  [ "$status" -eq 0 ]
}

@test "_is_lock_stale returns 0 for dead PID" {
  local lock_file="$TEST_PROJECT_DIR/.autopilot/locks/test.lock"
  echo "99999999" > "$lock_file"
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "99999999"
  [ "$status" -eq 0 ]
}

@test "_is_lock_stale returns 1 for live PID within time limit" {
  local lock_file="$TEST_PROJECT_DIR/.autopilot/locks/test.lock"
  echo "1" > "$lock_file"
  AUTOPILOT_STALE_LOCK_MINUTES=45
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "1"
  [ "$status" -eq 1 ]
}

@test "_is_lock_stale detects old lock with live PID" {
  local lock_file="$TEST_PROJECT_DIR/.autopilot/locks/test.lock"
  echo "1" > "$lock_file"
  # Set stale threshold to 0 minutes so lock is immediately stale
  AUTOPILOT_STALE_LOCK_MINUTES=0
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "1"
  [ "$status" -eq 0 ]
}

# --- _is_lock_file_old ---

@test "_is_lock_file_old returns 1 for nonexistent file" {
  run _is_lock_file_old "/nonexistent/file" 45
  [ "$status" -eq 1 ]
}

@test "_is_lock_file_old returns 1 for fresh file" {
  local lock_file="$TEST_PROJECT_DIR/.autopilot/locks/fresh.lock"
  echo "test" > "$lock_file"
  run _is_lock_file_old "$lock_file" 45
  [ "$status" -eq 1 ]
}

@test "_is_lock_file_old returns 0 for file with 0 minute threshold" {
  local lock_file="$TEST_PROJECT_DIR/.autopilot/locks/old.lock"
  echo "test" > "$lock_file"
  run _is_lock_file_old "$lock_file" 0
  [ "$status" -eq 0 ]
}

# --- Integration: acquire then release ---

@test "acquire and release cycle works correctly" {
  acquire_lock "$TEST_PROJECT_DIR" "test_lock"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/test_lock.lock" ]
  release_lock "$TEST_PROJECT_DIR" "test_lock"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/test_lock.lock" ]
}

@test "acquire after release succeeds" {
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  run acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "multiple named locks are independent" {
  acquire_lock "$TEST_PROJECT_DIR" "pipeline"
  acquire_lock "$TEST_PROJECT_DIR" "reviewer"
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/reviewer.lock" ]
  release_lock "$TEST_PROJECT_DIR" "pipeline"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock" ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/reviewer.lock" ]
}
