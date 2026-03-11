#!/usr/bin/env bats
# Tests for launchd plist template structure and autopilot-schedule CLI validation.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup_file() {
  # Snapshot real HOME before per-test setup overrides it.
  export _REAL_HOME="$HOME"

  # Build template mocks once.
  export _LAUNCHD_MOCK_BIN="${BATS_FILE_TMPDIR}/mock_bin"
  mkdir -p "$_LAUNCHD_MOCK_BIN"

  cat > "$_LAUNCHD_MOCK_BIN/launchctl" <<'MOCK'
#!/usr/bin/env bash
echo "launchctl $*" >> "${LAUNCHCTL_LOG:-/dev/null}"
exit 0
MOCK
  chmod +x "$_LAUNCHD_MOCK_BIN/launchctl"

  cat > "$_LAUNCHD_MOCK_BIN/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then echo "501"; fi
exit 0
MOCK
  chmod +x "$_LAUNCHD_MOCK_BIN/id"
}

teardown_file() {
  rm -rf "$_LAUNCHD_MOCK_BIN"
}

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_OUTPUT_DIR="$BATS_TEST_TMPDIR/output"
  # Reuse shared mock binaries (read-only, no test modifies them).
  MOCK_BIN="$_LAUNCHD_MOCK_BIN"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs" \
           "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  OLD_PATH="$PATH"
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  LAUNCHCTL_LOG="$TEST_OUTPUT_DIR/launchctl.log"
  export LAUNCHCTL_LOG
}

teardown() {
  PATH="$OLD_PATH"
  HOME="$_REAL_HOME"
  unset LAUNCHCTL_LOG
  unset AUTOPILOT_CLAUDE_CMD 2>/dev/null || true
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
  [[ "$output" == *"com.autopilot.dispatcher.my-acct_1"* ]]
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
