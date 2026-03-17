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

  # Resolve absolute project path for plist content.
  local abs_project_dir
  abs_project_dir="$(cd "$test_dir/project" && pwd)"

  # Create matching LaunchAgents plist for scheduler check (all cached runs).
  local home_dir
  for home_dir in "$test_dir/home" "$test_dir/home2" "$test_dir/home3"; do
    mkdir -p "$home_dir/Library/LaunchAgents"
    cat > "$home_dir/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" << PLIST
<plist><string>${abs_project_dir}</string></plist>
PLIST
  done

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

# --- Scheduler check ---

@test "doctor: fails when no launchd agents reference the project (macOS)" {
  # Remove the plist created by setup
  rm -rf "$HOME/Library/LaunchAgents"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] No scheduler found"* ]]
  [[ "$output" == *"autopilot-schedule"* ]]
}

@test "doctor: fails when launchd plist exists but references different project" {
  # Replace plist with one referencing a different project
  rm -rf "$HOME/Library/LaunchAgents"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" << 'PLIST'
<plist><string>/some/other/project</string></plist>
PLIST
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] No scheduler found"* ]]
}

@test "doctor: passes when matching launchd plist exists" {
  # Plist is already set up by _setup_scheduler_plist in setup()
  _run_doctor
  echo "$output"
  [[ "$output" == *"[PASS] Scheduler active"* ]]
}

@test "doctor: scheduler check passes in cached all-pass run" {
  [ "$_DOCTOR_CACHED_STATUS" -eq 0 ]
  [[ "$_DOCTOR_CACHED_OUTPUT" == *"[PASS] Scheduler active"* ]]
}

@test "doctor: fails when no crontab entries reference the project (Linux)" {
  _mock_uname "Linux"
  # Mock crontab with no matching entries
  cat > "$MOCK_BIN/crontab" << 'MOCK'
#!/usr/bin/env bash
echo "* * * * * /some/other/project/dispatch"
MOCK
  chmod +x "$MOCK_BIN/crontab"
  _run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] No scheduler found"* ]]
  [[ "$output" == *"crontab"* ]]
}

@test "doctor: passes when crontab entries reference the project (Linux)" {
  _mock_uname "Linux"
  # Get absolute project path for crontab mock
  local abs_project
  abs_project="$(cd "$TEST_DIR/project" && pwd)"
  # Mock crontab with matching entry
  cat > "$MOCK_BIN/crontab" << MOCK
#!/usr/bin/env bash
echo "* * * * * ${abs_project}/bin/autopilot-dispatch"
MOCK
  chmod +x "$MOCK_BIN/crontab"
  _run_doctor
  echo "$output"
  [[ "$output" == *"[PASS] Scheduler active"* ]]
}

# --- md5/md5sum check ---

@test "doctor: md5 check passes in cached all-pass run" {
  [[ "$_DOCTOR_CACHED_OUTPUT" == *"[PASS]"*"md5"* ]]
}

# --- ANSI color tests ---

@test "doctor: no ANSI codes when stdout is not a TTY (piped)" {
  # Cached output was captured via $(), so stdout was not a TTY — no colors expected.
  [[ "$_DOCTOR_CACHED_OUTPUT" != *$'\033['* ]]
}

@test "doctor: PASS lines include green ANSI when stdout is a TTY" {
  # Use script(1) to force a TTY for the subprocess.
  # script must run outside the restricted PATH, so we call it directly
  # and use env to set the restricted PATH inside.
  local test_dir="${BATS_TEST_TMPDIR}/tty_test"
  local mock_bin="${BATS_TEST_TMPDIR}/tty_mock"
  mkdir -p "$test_dir" "$mock_bin"

  _setup_valid_project "$test_dir/project"
  _setup_scheduler_plist "$test_dir/project" "$test_dir/home"
  cp "$MOCK_BIN"/* "$mock_bin/" 2>/dev/null || true

  local tty_output
  tty_output="$(HOME="$test_dir/home" \
    script -q /dev/null env PATH="$mock_bin:$UTILS_BIN" \
    "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  # Green escape: \033[32m
  [[ "$tty_output" == *$'\033[32m[PASS]'* ]]
}

@test "doctor: FAIL lines include red ANSI when stdout is a TTY" {
  local test_dir="${BATS_TEST_TMPDIR}/tty_fail"
  local mock_bin="${BATS_TEST_TMPDIR}/tty_fail_mock"
  mkdir -p "$test_dir" "$mock_bin"

  _setup_valid_project "$test_dir/project"
  _setup_scheduler_plist "$test_dir/project" "$test_dir/home"
  cp "$MOCK_BIN"/* "$mock_bin/" 2>/dev/null || true
  rm -f "$mock_bin/claude"

  local tty_output
  tty_output="$(HOME="$test_dir/home" \
    script -q /dev/null env PATH="$mock_bin:$UTILS_BIN" \
    "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  # Red escape: \033[31m
  [[ "$tty_output" == *$'\033[31m[FAIL]'* ]]
}

@test "doctor: WARN lines include yellow ANSI when stdout is a TTY" {
  local test_dir="${BATS_TEST_TMPDIR}/tty_warn"
  local mock_bin="${BATS_TEST_TMPDIR}/tty_warn_mock"
  mkdir -p "$test_dir" "$mock_bin"

  _setup_valid_project "$test_dir/project"
  _setup_scheduler_plist "$test_dir/project" "$test_dir/home"
  cp "$MOCK_BIN"/* "$mock_bin/" 2>/dev/null || true
  echo "# empty" > "$test_dir/project/autopilot.conf"

  local tty_output
  tty_output="$(HOME="$test_dir/home" \
    script -q /dev/null env PATH="$mock_bin:$UTILS_BIN" \
    "$REPO_DIR/bin/autopilot-doctor" "$test_dir/project" 2>&1)" || true
  # Yellow escape: \033[33m
  [[ "$tty_output" == *$'\033[33m[WARN]'* ]]
}

@test "doctor: reports FAIL when neither md5 nor md5sum is reachable" {
  # Remove md5 and md5sum from mock bins.
  rm -f "$MOCK_BIN/md5" "$MOCK_BIN/md5sum"

  # On macOS /sbin/md5 exists natively, so the check will PASS via the
  # absolute path fallback — which is correct behavior. We can only get
  # a true FAIL on a system where /sbin/md5 and /usr/bin/md5sum don't exist.
  _run_doctor
  echo "$output"

  if [[ -x /sbin/md5 ]] || [[ -x /usr/bin/md5sum ]]; then
    # Absolute path fallback found it — check passes (expected on macOS/Linux).
    [[ "$output" == *"[PASS]"*"md5"* ]]
  else
    # Neither found — should report FAIL.
    [[ "$output" == *"[FAIL] Neither md5 nor md5sum found"* ]]
  fi
}
