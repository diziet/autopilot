#!/usr/bin/env bats
# Tests for lib/entry-common.sh — Shared entry-point boilerplate:
# resolve_project_dir, resolve_lib_dir, parse_base_args,
# check_quick_guards, bootstrap_and_lock.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/entry-common.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/state.sh"
source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh"

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_EXTRA_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  load_config "$TEST_PROJECT_DIR"

  # Initialize state dir for guard tests.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_EXTRA_DIR"
}

# --- resolve_project_dir ---

@test "resolve_project_dir resolves relative path to absolute" {
  local result
  result="$(resolve_project_dir "$TEST_PROJECT_DIR")"
  [[ "$result" == /* ]]
}

@test "resolve_project_dir defaults to pwd" {
  local result
  result="$(resolve_project_dir)"
  [ "$result" = "$(pwd)" ]
}

@test "resolve_project_dir resolves . to current directory" {
  local result
  result="$(resolve_project_dir ".")"
  [ "$result" = "$(pwd)" ]
}

@test "resolve_project_dir returns empty on nonexistent path" {
  local result
  result="$(resolve_project_dir "/nonexistent/path/12345" 2>/dev/null)"
  [ -z "$result" ]
}

# --- resolve_lib_dir ---

@test "resolve_lib_dir derives lib path from script path" {
  local result
  result="$(resolve_lib_dir "$BATS_TEST_DIRNAME/../bin/autopilot-dispatch")"
  [[ "$result" == *"/lib" ]]
}

@test "resolve_lib_dir resolves relative script paths" {
  local result
  result="$(resolve_lib_dir "$BATS_TEST_DIRNAME/../bin/fake-script")"
  [[ "$result" == *"/../lib" ]] || [[ "$result" == */lib ]]
}

# --- parse_base_args ---

@test "parse_base_args sets PROJECT_DIR_ARG from positional argument" {
  # Define required _usage callback.
  _usage() { echo "Usage: test"; }

  parse_base_args "/some/path"
  [ "$PROJECT_DIR_ARG" = "/some/path" ]
}

@test "parse_base_args defaults to empty PROJECT_DIR_ARG with no args" {
  _usage() { echo "Usage: test"; }

  parse_base_args
  [ -z "$PROJECT_DIR_ARG" ]
}

@test "parse_base_args rejects unknown options" {
  _usage() { echo "Usage: test"; }

  run parse_base_args "--unknown-flag"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "parse_base_args rejects multiple positional arguments" {
  _usage() { echo "Usage: test"; }

  run parse_base_args "/path1" "/path2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected positional argument"* ]]
}

@test "parse_base_args handles --help flag" {
  _usage() { echo "Usage: test [project_dir]"; }

  run parse_base_args "--help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "parse_base_args handles -h flag" {
  _usage() { echo "Usage: test [project_dir]"; }

  run parse_base_args "-h"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "parse_base_args delegates to _handle_extra_flag when defined" {
  _usage() { echo "Usage: test"; }
  _handle_extra_flag() {
    case "$1" in
      --custom)
        EXTRA_FLAG_SHIFT=1
        CUSTOM_FLAG="true"
        return 0
        ;;
    esac
    return 1
  }

  CUSTOM_FLAG=""
  parse_base_args "--custom" "/path"
  [ "$CUSTOM_FLAG" = "true" ]
  [ "$PROJECT_DIR_ARG" = "/path" ]
}

@test "parse_base_args shows positional hint on extra arg error" {
  _usage() { echo "Usage: test"; }
  _EXTRA_POSITIONAL_HINT="only project dir is accepted"

  run parse_base_args "/path1" "/path2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only project dir is accepted"* ]]
}

# --- check_quick_guards ---

@test "check_quick_guards returns 0 when no guards triggered" {
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "check_quick_guards returns 1 when PAUSE file contains NOW (hard pause)" {
  echo "NOW" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "check_quick_guards returns 0 when PAUSE file is empty (soft pause)" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "check_quick_guards returns 1 when lock held by live process" {
  # Use our own PID (guaranteed alive) in the lock file.
  echo "$$" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "check_quick_guards returns 0 when lock held by dead process" {
  echo "999999" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "check_quick_guards returns 0 when no lock file exists" {
  run check_quick_guards "$TEST_PROJECT_DIR" "nonexistent_lock"
  [ "$status" -eq 0 ]
}

@test "check_quick_guards returns 1 when both hard PAUSE and live lock exist" {
  echo "NOW" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  echo "$$" > "$TEST_PROJECT_DIR/.autopilot/locks/pipeline.lock"

  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

# --- bootstrap_and_lock ---

@test "bootstrap_and_lock acquires lock and returns 0" {
  local lib_dir="$BATS_TEST_DIRNAME/../lib"

  bootstrap_and_lock "$TEST_PROJECT_DIR" "test_lock" "config.sh" "$lib_dir"
  local rc=$?
  [ "$rc" -eq 0 ]

  # Lock file should exist with our PID.
  [ -f "$TEST_PROJECT_DIR/.autopilot/locks/test_lock.lock" ]
  local lock_pid
  lock_pid="$(cat "$TEST_PROJECT_DIR/.autopilot/locks/test_lock.lock")"
  [ "$lock_pid" = "$$" ]

  # Clean up the lock manually (trap would do it on exit).
  release_lock "$TEST_PROJECT_DIR" "test_lock"
}

@test "bootstrap_and_lock fails when lock already held" {
  local lib_dir="$BATS_TEST_DIRNAME/../lib"

  # Pre-create lock with a different live PID.
  # Use a sleep process so the PID is alive.
  sleep 60 &
  local bg_pid=$!
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
  echo "$bg_pid" > "$TEST_PROJECT_DIR/.autopilot/locks/test_lock.lock"

  run bootstrap_and_lock "$TEST_PROJECT_DIR" "test_lock" "config.sh" "$lib_dir"
  [ "$status" -eq 1 ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "bootstrap_and_lock creates .autopilot directory structure" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot"
  local lib_dir="$BATS_TEST_DIRNAME/../lib"

  bootstrap_and_lock "$TEST_PROJECT_DIR" "init_test" "config.sh" "$lib_dir"
  [ -d "$TEST_PROJECT_DIR/.autopilot" ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/logs" ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/locks" ]

  release_lock "$TEST_PROJECT_DIR" "init_test"
}
