#!/usr/bin/env bats
# Tests for bin/autopilot-doctor — pre-run setup validation command.

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
  _setup_valid_project "$TEST_DIR/project"
  cd "$TEST_DIR/project"
}

teardown() {
  _teardown_isolated_env
}

# Run autopilot-doctor with isolated PATH.
_run_doctor() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-doctor" "$TEST_DIR/project"
}

# --- All checks pass ---

@test "doctor: passes when everything is configured" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
}

# --- Prerequisite failures ---

@test "doctor: fails when claude is missing" {
  rm -f "$MOCK_BIN/claude"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] claude not found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

@test "doctor: fails when gh is missing" {
  rm -f "$MOCK_BIN/gh"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] gh not found"* ]]
}

@test "doctor: fails when jq is missing" {
  rm -f "$MOCK_BIN/jq"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] jq not found"* ]]
}

@test "doctor: fails when git is missing" {
  rm -f "$MOCK_BIN/git"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] git not found"* ]]
}

@test "doctor: fails when timeout is missing with coreutils hint" {
  rm -f "$MOCK_BIN/timeout"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] timeout not found"* ]]
  [[ "$output" == *"brew install coreutils"* ]]
}

# --- gh auth failure ---

@test "doctor: fails when gh auth is not configured" {
  _mock_gh 1 0
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] gh not authenticated"* ]]
  [[ "$output" == *"gh auth login"* ]]
}

# --- Tasks file failures ---

@test "doctor: fails when tasks file is missing" {
  rm -f "$TEST_DIR/project/tasks.md"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] No tasks file found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

@test "doctor: fails when tasks file has no Task headings" {
  echo "# Just a title" > "$TEST_DIR/project/tasks.md"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Tasks file"* ]]
  [[ "$output" == *"no '## Task N' headings"* ]]
}

# --- Config failures ---

@test "doctor: fails when autopilot.conf is missing" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] autopilot.conf not found"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

# --- Gitignore failures ---

@test "doctor: fails when .gitignore is missing" {
  rm -f "$TEST_DIR/project/.gitignore"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] .gitignore not found"* ]]
}

@test "doctor: fails when .autopilot/ not in .gitignore" {
  echo "node_modules/" > "$TEST_DIR/project/.gitignore"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] .autopilot/ not in .gitignore"* ]]
}

# --- GitHub remote failure ---

@test "doctor: fails when GitHub remote is not reachable" {
  _mock_gh 0 1
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] GitHub remote not reachable"* ]]
}

# --- Claude smoke test failure ---

@test "doctor: fails when Claude smoke test fails" {
  _mock_claude 1
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Claude"* ]]
  [[ "$output" == *"API not responding"* ]]
  [[ "$output" == *"check(s) failed"* ]]
}

# --- Two-account detection ---

@test "doctor: detects two-account setup" {
  mkdir -p "$HOME/.claude-account1"
  mkdir -p "$HOME/.claude-account2"
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Two-account setup detected"* ]]
  [[ "$output" == *"Claude account 1"* ]]
  [[ "$output" == *"Claude account 2"* ]]
}

@test "doctor: warns when only one account detected" {
  mkdir -p "$HOME/.claude-account1"
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] Only one Claude account detected"* ]]
}

@test "doctor: single account with default config" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default config"* ]]
}

# --- Help flag ---

@test "doctor: --help prints usage" {
  run "$REPO_DIR/bin/autopilot-doctor" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"autopilot-doctor"* ]]
}

# --- Permissions flag warning ---

@test "doctor: warns when --dangerously-skip-permissions not set" {
  echo "# empty config" > "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"dangerously-skip-permissions"* ]]
}

@test "doctor: skips permissions check when config not loaded" {
  rm -f "$TEST_DIR/project/autopilot.conf"
  _run_doctor
  echo "$output"
  [[ "$output" == *"permissions check skipped — config not loaded"* ]]
}
