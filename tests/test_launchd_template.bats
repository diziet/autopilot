#!/usr/bin/env bats
# Tests for launchd plist template structure and autopilot-schedule CLI validation.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

load helpers/launchd_setup

setup_file() {
  export _REAL_HOME="$HOME"
  export _LAUNCHD_MOCK_BIN="${BATS_FILE_TMPDIR}/mock_bin"
  _create_launchd_mocks "$_LAUNCHD_MOCK_BIN"
}

teardown_file() {
  rm -rf "$_LAUNCHD_MOCK_BIN"
}

setup() {
  _launchd_test_setup
}

teardown() {
  _launchd_test_teardown
}

# --- Plist template existence and structure ---

@test "templates: unified agent plist template exists" {
  [ -f "$REPO_DIR/plists/com.autopilot.agent.plist" ]
}

@test "templates: agent plist is valid XML" {
  run xmllint --noout "$REPO_DIR/plists/com.autopilot.agent.plist"
  [ "$status" -eq 0 ]
}

@test "templates: agent plist contains all substitution markers" {
  local plist="$REPO_DIR/plists/com.autopilot.agent.plist"
  grep -q '__AUTOPILOT_PROJECT_DIR__' "$plist"
  grep -q '__AUTOPILOT_ACCOUNT__' "$plist"
  grep -q '__AUTOPILOT_START_INTERVAL__' "$plist"
  grep -q '__AUTOPILOT_BIN_DIR__' "$plist"
  grep -q '__CLAUDE_BIN_DIR__' "$plist"
  grep -q '__HOME__' "$plist"
  grep -q '__AUTOPILOT_HOME__' "$plist"
  grep -q '__AUTOPILOT_LOG_DIR__' "$plist"
  grep -q '__AUTOPILOT_ROLE__' "$plist"
  grep -q '__AUTOPILOT_COMMAND__' "$plist"
  grep -q '__AUTOPILOT_EXTRA_ENV_KEY__' "$plist"
  grep -q '__AUTOPILOT_EXTRA_ENV_VAL__' "$plist"
}

@test "templates: agent plist has KeepAlive false" {
  grep -q '<key>KeepAlive</key>' "$REPO_DIR/plists/com.autopilot.agent.plist"
  grep -q '<false/>' "$REPO_DIR/plists/com.autopilot.agent.plist"
}

@test "templates: agent plist has StandardOutPath" {
  grep -q '<key>StandardOutPath</key>' "$REPO_DIR/plists/com.autopilot.agent.plist"
}

@test "templates: agent plist has StandardErrorPath" {
  grep -q '<key>StandardErrorPath</key>' "$REPO_DIR/plists/com.autopilot.agent.plist"
}

@test "templates: agent plist has PATH env var" {
  grep -q '<key>PATH</key>' "$REPO_DIR/plists/com.autopilot.agent.plist"
}

@test "templates: agent plist PATH includes __HOME__/.local/bin" {
  local path_line
  path_line="$(grep -A1 '<key>PATH</key>' "$REPO_DIR/plists/com.autopilot.agent.plist" | tail -1)"
  [[ "$path_line" == *"__HOME__/.local/bin"* ]]
}

# --- autopilot-schedule existence and help ---

@test "schedule: autopilot-schedule exists and is executable" {
  [ -f "$REPO_DIR/bin/autopilot-schedule" ]
  [ -x "$REPO_DIR/bin/autopilot-schedule" ]
}

@test "schedule: --help shows usage" {
  run "$REPO_DIR/bin/autopilot-schedule" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"PROJECT_DIR"* ]]
}

@test "schedule: -h shows usage" {
  run "$REPO_DIR/bin/autopilot-schedule" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "schedule: fails without PROJECT_DIR" {
  run "$REPO_DIR/bin/autopilot-schedule"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT_DIR is required"* ]]
}

@test "schedule: fails with nonexistent directory" {
  run "$REPO_DIR/bin/autopilot-schedule" /nonexistent/path
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory not found"* ]]
}

@test "schedule: fails with invalid interval" {
  run "$REPO_DIR/bin/autopilot-schedule" --interval 0 "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "schedule: fails with non-numeric interval" {
  run "$REPO_DIR/bin/autopilot-schedule" --interval abc "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "schedule: rejects unknown option" {
  run "$REPO_DIR/bin/autopilot-schedule" --bogus "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "schedule: rejects invalid account with special chars" {
  run "$REPO_DIR/bin/autopilot-schedule" --account "../evil" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alphanumeric"* ]]
}

@test "schedule: rejects account with spaces" {
  run "$REPO_DIR/bin/autopilot-schedule" --account "hello world" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alphanumeric"* ]]
}

@test "schedule: accepts alphanumeric account with hyphens" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account "my-acct_1" "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_LABEL_PREFIX}.dispatcher.my-acct_1"* ]]
}

@test "schedule: rejects --uninstall combined with --generate-only" {
  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "schedule: rejects --generate-only combined with --uninstall" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --uninstall "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "schedule: rejects --list combined with --uninstall" {
  run "$REPO_DIR/bin/autopilot-schedule" --list --uninstall "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]
}

@test "schedule: rejects --list combined with --generate-only" {
  run "$REPO_DIR/bin/autopilot-schedule" --list --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]
}
