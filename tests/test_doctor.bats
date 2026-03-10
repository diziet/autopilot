#!/usr/bin/env bats
# Tests for bin/autopilot-doctor — pre-run setup validation command.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup_file() {
  _create_mock_template

  # Run doctor once with "all pass" config and cache output for assertion tests.
  # This avoids re-running the full script for tests that check output content.
  local test_dir="${BATS_FILE_TMPDIR}/cached_doctor"
  local mock_bin="${BATS_FILE_TMPDIR}/cached_mock_bin"
  mkdir -p "$test_dir" "$mock_bin"

  # Set up valid project.
  if [[ -n "${_PROJECT_TEMPLATE_DIR:-}" && -d "$_PROJECT_TEMPLATE_DIR" ]]; then
    cp -r "$_PROJECT_TEMPLATE_DIR" "$test_dir/project"
  else
    mkdir -p "$test_dir/project"
    echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$test_dir/project/autopilot.conf"
    echo '.autopilot/' > "$test_dir/project/.gitignore"
    cat > "$test_dir/project/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS
  fi

  # Copy mocks.
  if [[ -n "${_MOCK_TEMPLATE_DIR:-}" && -d "$_MOCK_TEMPLATE_DIR" ]]; then
    cp "$_MOCK_TEMPLATE_DIR"/* "$mock_bin/" 2>/dev/null || true
  fi

  # Run doctor with default config (single account, no dirs).
  export _DOCTOR_CACHED_OUTPUT
  _DOCTOR_CACHED_OUTPUT="$(HOME="$test_dir/home" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  export _DOCTOR_CACHED_STATUS=$?

  # Run doctor with two-account setup and cache.
  mkdir -p "$test_dir/home2/.claude-account1" "$test_dir/home2/.claude-account2"
  export _DOCTOR_TWO_ACCT_OUTPUT
  _DOCTOR_TWO_ACCT_OUTPUT="$(HOME="$test_dir/home2" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  export _DOCTOR_TWO_ACCT_STATUS=$?

  # Run doctor with one-account setup and cache.
  mkdir -p "$test_dir/home3/.claude-account1"
  export _DOCTOR_ONE_ACCT_OUTPUT
  _DOCTOR_ONE_ACCT_OUTPUT="$(HOME="$test_dir/home3" PATH="$mock_bin:${_UTILS_TEMPLATE_DIR}" "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  export _DOCTOR_ONE_ACCT_STATUS=$?
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
  [ "$_DOCTOR_CACHED_STATUS" -eq 0 ]
  [[ "$_DOCTOR_CACHED_OUTPUT" == *"All checks passed"* ]]
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

# --- Two-account detection (use cached output) ---

@test "doctor: detects two-account setup" {
  [ "$_DOCTOR_TWO_ACCT_STATUS" -eq 0 ]
  [[ "$_DOCTOR_TWO_ACCT_OUTPUT" == *"Two-account setup detected"* ]]
  [[ "$_DOCTOR_TWO_ACCT_OUTPUT" == *"Claude account 1"* ]]
  [[ "$_DOCTOR_TWO_ACCT_OUTPUT" == *"Claude account 2"* ]]
}

@test "doctor: warns when only one account detected" {
  [ "$_DOCTOR_ONE_ACCT_STATUS" -eq 0 ]
  [[ "$_DOCTOR_ONE_ACCT_OUTPUT" == *"[WARN] Only one Claude account detected"* ]]
}

@test "doctor: single account with default config" {
  [ "$_DOCTOR_CACHED_STATUS" -eq 0 ]
  [[ "$_DOCTOR_CACHED_OUTPUT" == *"default config"* ]]
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
