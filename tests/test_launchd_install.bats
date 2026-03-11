#!/usr/bin/env bats
# Tests for launchd install/uninstall, account isolation, per-role accounts,
# Claude binary PATH detection, and Makefile targets.

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

# --- Install flow (mocked launchctl) ---

@test "install: calls launchctl bootstrap for both agents" {

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'bootstrap' "$LAUNCHCTL_LOG"
}

@test "install: creates plist files in LaunchAgents" {

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
}

@test "install: plist files contain correct project path" {

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  local plist="$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist"
  grep -q "$TEST_PROJECT_DIR" "$plist"
}

@test "install: output mentions both agents" {

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatcher"* ]]
  [[ "$output" == *"reviewer"* ]]
}

@test "install: creates log directory" {

  rm -rf "$TEST_PROJECT_DIR/.autopilot/logs"

  run "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/logs" ]
}

# --- Uninstall flow (mocked launchctl) ---

@test "uninstall: calls launchctl bootout" {

  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  > "$LAUNCHCTL_LOG"

  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'bootout' "$LAUNCHCTL_LOG"
}

@test "uninstall: removes plist files" {

  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]

  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 1 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
}

@test "uninstall: handles missing plists gracefully" {

  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --account 99 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not found"* ]]
}

# --- Account isolation ---

@test "accounts: different accounts produce different labels" {

  "$REPO_DIR/bin/autopilot-schedule" --account 1 "$TEST_PROJECT_DIR"
  "$REPO_DIR/bin/autopilot-schedule" --account 2 "$TEST_PROJECT_DIR"

  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.2.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

# --- Per-role accounts ---

@test "per-role: dispatcher-account and reviewer-account produce split labels" {

  run "$REPO_DIR/bin/autopilot-schedule" --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

@test "per-role: generate-only shows different accounts per role" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 3 --reviewer-account 7 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.3"* ]]
  [[ "$output" == *"com.autopilot.reviewer.7"* ]]
}

@test "per-role: CLAUDE_CONFIG_DIR set when config dir exists" {
  mkdir -p "$TEST_OUTPUT_DIR/.claude-account99"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 99 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" == *".claude-account99"* ]]
}

@test "per-role: CLAUDE_CONFIG_DIR omitted when config dir missing" {

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --dispatcher-account 98 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CLAUDE_CONFIG_DIR"* ]]
}

@test "per-role: uninstall with split accounts removes correct plists" {

  "$REPO_DIR/bin/autopilot-schedule" --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]

  run "$REPO_DIR/bin/autopilot-schedule" --uninstall --dispatcher-account 1 --reviewer-account 2 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" ]
  [ ! -f "$TEST_OUTPUT_DIR/Library/LaunchAgents/com.autopilot.reviewer.2.plist" ]
}

@test "per-role: defaults to --account when per-role flags omitted" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 5 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.5"* ]]
  [[ "$output" == *"com.autopilot.reviewer.5"* ]]
}

# --- Claude binary PATH detection ---

@test "claude-path: includes claude dir when claude is in ~/.local/bin" {
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
  echo "$output" | grep -q "$TEST_OUTPUT_DIR/.local/bin"
}

@test "claude-path: no extra dir when claude is in /opt/homebrew/bin" {
  PATH="$MOCK_BIN:$OLD_PATH"
  export AUTOPILOT_CLAUDE_CMD="/opt/homebrew/bin/claude"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  local path_line
  path_line="$(echo "$output" | grep '/opt/homebrew/bin' | head -1)"
  local count
  count="$(echo "$path_line" | grep -o '/opt/homebrew/bin' | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "claude-path: absolute AUTOPILOT_CLAUDE_CMD extracts directory" {
  PATH="$MOCK_BIN:$OLD_PATH"
  local custom_dir="$TEST_OUTPUT_DIR/custom-claude-dir"
  mkdir -p "$custom_dir"
  export AUTOPILOT_CLAUDE_CMD="$custom_dir/claude"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$custom_dir"
}

@test "claude-path: bare command resolved via PATH" {
  local custom_bin="$BATS_TEST_TMPDIR/custom_bin"
  mkdir -p "$custom_bin"
  cat > "$custom_bin/my-claude" <<'MOCK'
#!/usr/bin/env bash
echo "mock my-claude"
MOCK
  chmod +x "$custom_bin/my-claude"

  export AUTOPILOT_CLAUDE_CMD="my-claude"
  PATH="$custom_bin:$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$custom_bin"
}

@test "claude-path: adds HOME/.local/bin fallback when it exists" {
  mkdir -p "$TEST_OUTPUT_DIR/.local/bin"
  local custom_dir="$TEST_OUTPUT_DIR/other-claude-dir"
  mkdir -p "$custom_dir"
  export AUTOPILOT_CLAUDE_CMD="$custom_dir/claude"
  PATH="$MOCK_BIN:$OLD_PATH"

  run "$REPO_DIR/bin/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$custom_dir"
  echo "$output" | grep -q "$TEST_OUTPUT_DIR/.local/bin"
}

@test "claude-path: no duplicate when claude dir equals ~/.local/bin" {
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
