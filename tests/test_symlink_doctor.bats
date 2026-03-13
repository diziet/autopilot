#!/usr/bin/env bats
# Tests for symlink check in autopilot-doctor.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup_file() {
  _create_mock_template
}

teardown_file() {
  _cleanup_mock_template
}

setup() {
  _setup_isolated_env
  EXTERNAL_SYMLINK_DIR=""

  # Need real git for symlink tests.
  local real_git
  real_git="$(command -v git)"
  ln -sf "$real_git" "$MOCK_BIN/git"

  _setup_real_git_project "$TEST_DIR/project"
  _setup_scheduler_plist "$TEST_DIR/project"
  cd "$TEST_DIR/project"
}

teardown() {
  _teardown_isolated_env
}

# Run autopilot-doctor with isolated PATH.
_run_doctor() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-doctor" "$TEST_DIR/project"
}

@test "doctor: passes symlink check when no escaping symlinks" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] No symlinks escaping repo root"* ]]
}

@test "doctor: warns when escaping symlinks detected" {
  _add_escaping_symlink "$TEST_DIR/project" "ext_link"

  _run_doctor
  echo "$output"
  # Doctor still passes overall (symlinks are WARN not FAIL).
  [[ "$output" == *"[WARN] Symlinks that escape repo found"* ]]
  [[ "$output" == *"ext_link"* ]]
  [[ "$output" == *"AUTOPILOT_USE_WORKTREES=false"* ]]
}
