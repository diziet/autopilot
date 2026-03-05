#!/usr/bin/env bats
# Tests for launchd plist generation and variable substitution.
# Covers: plist templates, autopilot-schedule, Makefile targets.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_OUTPUT_DIR="$(mktemp -d)"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  # Mock launchctl to avoid actually loading plists
  MOCK_BIN="$(mktemp -d)"
  cat > "$MOCK_BIN/launchctl" <<'MOCK'
#!/usr/bin/env bash
echo "launchctl $*" >> "${LAUNCHCTL_LOG:-/dev/null}"
exit 0
MOCK
  chmod +x "$MOCK_BIN/launchctl"

  # Mock id command for consistent uid
  cat > "$MOCK_BIN/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then
  echo "501"
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/id"

  OLD_PATH="$PATH"
  LAUNCHCTL_LOG="$TEST_OUTPUT_DIR/launchctl.log"
  export LAUNCHCTL_LOG
}

teardown() {
  PATH="$OLD_PATH"
  unset LAUNCHCTL_LOG
  rm -rf "$TEST_PROJECT_DIR" "$TEST_OUTPUT_DIR" "$MOCK_BIN"
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
  grep -q '__AUTOPILOT_HOME__' "$plist"
  grep -q '__AUTOPILOT_LOG_DIR__' "$plist"
  grep -q '__AUTOPILOT_ROLE__' "$plist"
  grep -q '__AUTOPILOT_COMMAND__' "$plist"
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
  PATH="$MOCK_BIN:$PATH"
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

# --- Plist generation (--generate-only) ---

@test "generate: produces valid XML for dispatcher" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Extract dispatcher plist (before the --- separator)
  local dispatcher_plist
  dispatcher_plist="$(echo "$output" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | xmllint --noout -
}

@test "generate: substitutes project directory" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_PROJECT_DIR"* ]]
  [[ "$output" != *"__AUTOPILOT_PROJECT_DIR__"* ]]
}

@test "generate: substitutes account number" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 42 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.42"* ]]
  [[ "$output" == *"com.autopilot.reviewer.42"* ]]
  [[ "$output" != *"__AUTOPILOT_ACCOUNT__"* ]]
}

@test "generate: substitutes default interval (15)" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<integer>15</integer>"* ]]
  [[ "$output" != *"__AUTOPILOT_START_INTERVAL__"* ]]
}

@test "generate: substitutes custom interval" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --interval 30 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<integer>30</integer>"* ]]
}

@test "generate: substitutes HOME directory" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME"* ]]
  [[ "$output" != *"__AUTOPILOT_HOME__"* ]]
}

@test "generate: substitutes log directory" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_PROJECT_DIR}/.autopilot/logs"* ]]
  [[ "$output" != *"__AUTOPILOT_LOG_DIR__"* ]]
}

@test "generate: substitutes bin directory" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"__AUTOPILOT_BIN_DIR__"* ]]
}

@test "generate: no substitution markers remain" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q '__AUTOPILOT_'; then
    echo "Unsubstituted markers found in output:"
    echo "$output" | grep '__AUTOPILOT_'
    return 1
  fi
}

@test "generate: dispatcher label includes account" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.3"* ]]
}

@test "generate: reviewer label includes account" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.reviewer.3"* ]]
}

@test "generate: output contains both dispatcher and reviewer" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot-dispatch"* ]]
  [[ "$output" == *"autopilot-review"* ]]
}

@test "generate: dispatcher has KeepAlive false" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  local dispatcher_plist
  dispatcher_plist="$(echo "$output" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | grep -q '<false/>'
}

# --- Install flow (mocked launchctl) ---

@test "install: calls launchctl bootstrap for both agents" {
  PATH="$MOCK_BIN:$PATH"
  # Override LAUNCH_AGENTS_DIR to temp dir
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Check launchctl was called with bootstrap
  grep -q 'bootstrap' "$LAUNCHCTL_LOG"
}

@test "install: creates plist files in LaunchAgents" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
}

@test "install: plist files contain correct project path" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  local plist="$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist"
  grep -q "$TEST_PROJECT_DIR" "$plist"
}

@test "install: output mentions both agents" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatcher"* ]]
  [[ "$output" == *"reviewer"* ]]
}

@test "install: creates log directory" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  # Remove the log dir to verify it gets created
  rm -rf "$TEST_PROJECT_DIR/.autopilot/logs"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/logs" ]
}

# --- Uninstall flow (mocked launchctl) ---

@test "uninstall: calls launchctl bootout" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  # First install
  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"

  # Reset log
  > "$LAUNCHCTL_LOG"

  # Then uninstall
  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'bootout' "$LAUNCHCTL_LOG"
}

@test "uninstall: removes plist files" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  # First install
  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]

  # Then uninstall
  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
}

@test "uninstall: handles missing plists gracefully" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 99 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not found"* ]]
}

# --- Account isolation ---

@test "accounts: different accounts produce different labels" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  "$REPO_DIR/bin/autopilot-schedule" --account 2 "$TEST_PROJECT_DIR"

  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.2.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

# --- Symlink resolution ---

@test "symlink: autopilot-schedule works via symlink" {
  PATH="$MOCK_BIN:$PATH"
  local symlink_dir
  symlink_dir="$(mktemp -d)"

  ln -sf "$REPO_DIR/bin/autopilot-schedule" "$symlink_dir/autopilot-schedule"
  run "$symlink_dir/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  rm -rf "$symlink_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot-dispatch"* ]]
  [[ "$output" == *"autopilot-review"* ]]
  [[ "$output" != *"__AUTOPILOT_"* ]]
}

# --- Makefile targets ---

@test "makefile: install-launchd target exists" {
  run make -C "$REPO_DIR" -n install-launchd PROJECT="$TEST_PROJECT_DIR" 2>&1
  [ "$status" -eq 0 ]
}

@test "makefile: uninstall-launchd target exists" {
  run make -C "$REPO_DIR" -n uninstall-launchd PROJECT="$TEST_PROJECT_DIR" 2>&1
  [ "$status" -eq 0 ]
}

@test "makefile: install-launchd fails without PROJECT" {
  run make -C "$REPO_DIR" install-launchd 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT is required"* ]]
}

@test "makefile: uninstall-launchd fails without PROJECT" {
  run make -C "$REPO_DIR" uninstall-launchd 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT is required"* ]]
}
