#!/usr/bin/env bats
# Tests for launchd plist generation and variable substitution.
# Covers: plist templates, autopilot-schedule, Makefile targets.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_OUTPUT_DIR="$BATS_TEST_TMPDIR/output"
  MOCK_BIN="$BATS_TEST_TMPDIR/mock_bin"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs" "$TEST_OUTPUT_DIR" "$MOCK_BIN"

  # Mock launchctl to avoid actually loading plists
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
  [[ "$output" != *"__HOME__"* ]]
}

@test "generate: PATH includes HOME/.local/bin" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Extract the PATH value line from the generated plist
  local path_value
  path_value="$(echo "$output" | grep -A1 '<key>PATH</key>' | tail -1)"
  # Verify ~/.local/bin is present in the substituted PATH
  [[ "$path_value" == *"${HOME}/.local/bin"* ]]
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
  if echo "$output" | grep -qE '__AUTOPILOT_|__CLAUDE_|__HOME__'; then
    echo "Unsubstituted markers found in output:"
    echo "$output" | grep -E '__AUTOPILOT_|__CLAUDE_|__HOME__'
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

# --- Per-role accounts ---

@test "per-role: dispatcher-account and reviewer-account produce split labels" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  run "$REPO_DIR/bin/autopilot-schedule" --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

@test "per-role: generate-only shows different accounts per role" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 3 --reviewer-account 7 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.3"* ]]
  [[ "$output" == *"com.autopilot.reviewer.7"* ]]
}

@test "per-role: CLAUDE_CONFIG_DIR set when config dir exists" {
  PATH="$MOCK_BIN:$PATH"
  # Create a fake config dir for account 99
  mkdir -p "$TEST_OUTPUT_DIR/.claude-account99"
  export HOME="$TEST_OUTPUT_DIR"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 99 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" == *".claude-account99"* ]]
}

@test "per-role: CLAUDE_CONFIG_DIR omitted when config dir missing" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  # No .claude-account98 directory exists

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 98 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CLAUDE_CONFIG_DIR"* ]]
}

@test "per-role: uninstall with split accounts removes correct plists" {
  PATH="$MOCK_BIN:$PATH"
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/Library/LaunchAgents"

  # Install with split accounts
  "$REPO_DIR/bin/autopilot-schedule" --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]

  # Uninstall with same split accounts
  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

@test "per-role: defaults to --account when per-role flags omitted" {
  PATH="$MOCK_BIN:$PATH"
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 5 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.5"* ]]
  [[ "$output" == *"com.autopilot.reviewer.5"* ]]
}

# --- Symlink resolution ---

@test "symlink: autopilot-schedule works via symlink" {
  PATH="$MOCK_BIN:$PATH"
  local symlink_dir="$BATS_TEST_TMPDIR/symlink_dir"
  mkdir -p "$symlink_dir"

  ln -sf "$REPO_DIR/bin/autopilot-schedule" "$symlink_dir/autopilot-schedule"
  run "$symlink_dir/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot-dispatch"* ]]
  [[ "$output" == *"autopilot-review"* ]]
  [[ "$output" != *"__AUTOPILOT_"* ]]
  [[ "$output" != *"__CLAUDE_"* ]]
  [[ "$output" != *"__HOME__"* ]]
}

# --- Claude binary PATH detection ---

@test "claude-path: includes claude dir when claude is in ~/.local/bin" {
  export HOME="$TEST_OUTPUT_DIR"
  # Create mock claude in ~/.local/bin
  mkdir -p "$TEST_OUTPUT_DIR/.local/bin"
  cat > "$TEST_OUTPUT_DIR/.local/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "mock claude"
MOCK
  chmod +x "$TEST_OUTPUT_DIR/.local/bin/claude"

  # Put mock claude dir first so command -v finds it
  PATH="$TEST_OUTPUT_DIR/.local/bin:$MOCK_BIN:$OLD_PATH"
  unset AUTOPILOT_CLAUDE_CMD

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # PATH in output should contain ~/.local/bin
  echo "$output" | grep -q "$TEST_OUTPUT_DIR/.local/bin"
}

@test "claude-path: no extra dir when claude is in /opt/homebrew/bin" {
  PATH="$MOCK_BIN:$OLD_PATH"
  # Use absolute path pointing to /opt/homebrew/bin (already in static PATH)
  export AUTOPILOT_CLAUDE_CMD="/opt/homebrew/bin/claude"
  export HOME="$TEST_OUTPUT_DIR"
  # Ensure ~/.local/bin does NOT exist (no fallback added)

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Extract the PATH value from the plist output
  local path_line
  path_line="$(echo "$output" | grep '/opt/homebrew/bin' | head -1)"
  # /opt/homebrew/bin should appear exactly once (not duplicated)
  local count
  count="$(echo "$path_line" | grep -o '/opt/homebrew/bin' | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "claude-path: absolute AUTOPILOT_CLAUDE_CMD extracts directory" {
  PATH="$MOCK_BIN:$OLD_PATH"
  local custom_dir="$TEST_OUTPUT_DIR/custom-claude-dir"
  mkdir -p "$custom_dir"
  export AUTOPILOT_CLAUDE_CMD="$custom_dir/claude"
  export HOME="$TEST_OUTPUT_DIR"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # PATH in output should contain the custom directory
  echo "$output" | grep -q "$custom_dir"
}

@test "claude-path: bare command resolved via PATH" {
  export HOME="$TEST_OUTPUT_DIR"
  # Create mock custom-claude in a temp dir
  local custom_bin="$BATS_TEST_TMPDIR/custom_bin"
  mkdir -p "$custom_bin"
  cat > "$custom_bin/my-claude" <<'MOCK'
#!/usr/bin/env bash
echo "mock my-claude"
MOCK
  chmod +x "$custom_bin/my-claude"

  # Set bare command name and put its dir in PATH
  export AUTOPILOT_CLAUDE_CMD="my-claude"
  PATH="$custom_bin:$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # PATH in output should contain the custom bin directory
  echo "$output" | grep -q "$custom_bin"
}

@test "claude-path: adds HOME/.local/bin fallback when it exists" {
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/.local/bin"
  # Claude is in a different custom dir
  local custom_dir="$TEST_OUTPUT_DIR/other-claude-dir"
  mkdir -p "$custom_dir"
  export AUTOPILOT_CLAUDE_CMD="$custom_dir/claude"
  PATH="$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Both custom dir and ~/.local/bin should be in PATH
  echo "$output" | grep -q "$custom_dir"
  echo "$output" | grep -q "$TEST_OUTPUT_DIR/.local/bin"
}

@test "claude-path: no duplicate when claude dir equals ~/.local/bin" {
  export HOME="$TEST_OUTPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR/.local/bin"
  cat > "$TEST_OUTPUT_DIR/.local/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "mock claude"
MOCK
  chmod +x "$TEST_OUTPUT_DIR/.local/bin/claude"

  PATH="$TEST_OUTPUT_DIR/.local/bin:$MOCK_BIN:$OLD_PATH"
  unset AUTOPILOT_CLAUDE_CMD

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # ~/.local/bin should appear in PATH but not duplicated
  local path_line
  path_line="$(echo "$output" | grep "$TEST_OUTPUT_DIR/.local/bin" | head -1)"
  local count
  count="$(echo "$path_line" | grep -o "$TEST_OUTPUT_DIR/.local/bin" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
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
