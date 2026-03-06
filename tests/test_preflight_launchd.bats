#!/usr/bin/env bats
# Tests for launchd PATH validation in lib/preflight.sh.
# Validates that check_launchd_path warns when dependencies are not
# findable under the PATH configured in launchd plist files.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Create a valid git repo in the test project dir.
  git -C "$TEST_PROJECT_DIR" init -q
  touch "$TEST_PROJECT_DIR/dummy.txt"
  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -q -m "initial"

  # Create required project files.
  echo "# Tasks" > "$TEST_PROJECT_DIR/tasks.md"
  echo "## Task 1" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "# Project CLAUDE.md" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create mock gh for auth tests.
  _create_gh_mock 0
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Source preflight.sh (which sources config, state, tasks).
  source "$BATS_TEST_DIRNAME/../lib/preflight.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  HOME="$OLD_HOME"
  rm -rf "$TEST_PROJECT_DIR" "$MOCK_BIN"
}

# Create a mock executable that exits with a given code.
_create_mock() {
  local path="$1"
  local exit_code="${2:-0}"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
exit $exit_code
MOCK
  chmod +x "$path"
}

# Create a gh mock that simulates auth status.
_create_gh_mock() {
  local exit_code="${1:-0}"
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "auth" && "\$2" == "status" ]]; then
  exit $exit_code
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/gh"
}

# Create a mock plist file with given WorkingDirectory and PATH.
_create_mock_plist() {
  local dest="$1" working_dir="$2" path_val="$3"
  cat > "$dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${path_val}</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${working_dir}</string>
</dict>
</plist>
PLIST
}

# Set up a fake HOME with LaunchAgents directory.
_setup_fake_home() {
  local fake_home
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/Library/LaunchAgents"
  echo "$fake_home"
}

# --- _extract_plist_working_dir ---

@test "_extract_plist_working_dir parses WorkingDirectory from plist" {
  local plist_file="${MOCK_BIN}/test.plist"
  _create_mock_plist "$plist_file" "/some/project/dir" "/usr/bin:/bin"
  local result
  result="$(_extract_plist_working_dir "$plist_file")"
  [[ "$result" == "/some/project/dir" ]]
}

# --- _extract_plist_path ---

@test "_extract_plist_path parses PATH from plist" {
  local plist_file="${MOCK_BIN}/test.plist"
  _create_mock_plist "$plist_file" "/some/dir" "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
  local result
  result="$(_extract_plist_path "$plist_file")"
  [[ "$result" == "/opt/homebrew/bin:/usr/local/bin:/usr/bin" ]]
}

# --- _command_in_path ---

@test "_command_in_path finds executable in specified PATH" {
  _create_mock "$MOCK_BIN/mycmd" 0
  _command_in_path "mycmd" "$MOCK_BIN"
}

@test "_command_in_path searches multiple PATH entries" {
  local extra_bin
  extra_bin="$(mktemp -d)"
  _create_mock "$extra_bin/mycmd" 0
  _command_in_path "mycmd" "/nonexistent:${extra_bin}:/also/nonexistent"
  rm -rf "$extra_bin"
}

@test "_command_in_path fails when command not found" {
  ! _command_in_path "nosuchcmd_xyz" "/usr/bin:/bin"
}

# --- _find_project_plists ---

@test "_find_project_plists returns plists matching project dir" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.dispatcher.1.plist" \
    "$TEST_PROJECT_DIR" "/usr/bin:/bin"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.other.plist" \
    "/different/project" "/usr/bin"

  HOME="$fake_home"
  local result
  result="$(_find_project_plists "$TEST_PROJECT_DIR")"

  [[ "$result" == *"com.autopilot.dispatcher.1.plist"* ]]
  [[ "$result" != *"com.other.plist"* ]]
  rm -rf "$fake_home"
}

@test "_find_project_plists returns nothing when no plists match" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.plist" \
    "/other/project" "/usr/bin"

  HOME="$fake_home"
  local result
  result="$(_find_project_plists "$TEST_PROJECT_DIR")"

  [[ -z "$result" ]]
  rm -rf "$fake_home"
}

@test "_find_project_plists returns empty when LaunchAgents dir missing" {
  local fake_home
  fake_home="$(mktemp -d)"
  # No Library/LaunchAgents — should return empty.
  HOME="$fake_home"
  local result
  result="$(_find_project_plists "$TEST_PROJECT_DIR")"

  [[ -z "$result" ]]
  rm -rf "$fake_home"
}

# --- check_launchd_path ---

@test "check_launchd_path returns 0 when no plist exists" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  HOME="$fake_home"
  run check_launchd_path "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  rm -rf "$fake_home"
}

@test "check_launchd_path warns when dep missing from launchd PATH" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "/nonexistent/path"

  HOME="$fake_home"
  run check_launchd_path "$TEST_PROJECT_DIR"

  # Should still return 0 (non-fatal).
  [ "$status" -eq 0 ]

  # Should have logged warnings.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"WARNING"* ]]
  [[ "$log_content" == *"launchd plist PATH"* ]]
  [[ "$log_content" == *"autopilot-schedule"* ]]
  rm -rf "$fake_home"
}

@test "check_launchd_path no warnings when all deps in launchd PATH" {
  # Create a bin dir with all required deps.
  local dep_bin
  dep_bin="$(mktemp -d)"
  for cmd in claude gh jq git timeout; do
    _create_mock "$dep_bin/$cmd" 0
  done

  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "$dep_bin"

  # Clear log to check for new warnings only.
  : > "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  HOME="$fake_home"
  check_launchd_path "$TEST_PROJECT_DIR"

  # No launchd warnings should be logged.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" != *"launchd plist PATH"* ]]
  rm -rf "$dep_bin" "$fake_home"
}

@test "check_launchd_path warns with dep location when on shell PATH but not launchd PATH" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "/nonexistent/bin"

  HOME="$fake_home"
  run check_launchd_path "$TEST_PROJECT_DIR"

  [ "$status" -eq 0 ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  # Should mention the actual path where a dep was found.
  [[ "$log_content" == *"found at"* ]]
  [[ "$log_content" == *"is not in the launchd plist PATH"* ]]
  rm -rf "$fake_home"
}

@test "check_launchd_path uses AUTOPILOT_CLAUDE_CMD for claude check" {
  local dep_bin
  dep_bin="$(mktemp -d)"
  for cmd in gh jq git timeout; do
    _create_mock "$dep_bin/$cmd" 0
  done
  _create_mock "$dep_bin/my-claude" 0

  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "$dep_bin"

  AUTOPILOT_CLAUDE_CMD="my-claude"
  : > "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  HOME="$fake_home"
  check_launchd_path "$TEST_PROJECT_DIR"

  # No warnings — my-claude is in the launchd PATH.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" != *"launchd plist PATH"* ]]
  rm -rf "$dep_bin" "$fake_home"
}

@test "check_launchd_path handles absolute AUTOPILOT_CLAUDE_CMD without false warning" {
  local dep_bin
  dep_bin="$(mktemp -d)"
  for cmd in gh jq git timeout; do
    _create_mock "$dep_bin/$cmd" 0
  done
  # Create claude at an absolute path inside dep_bin.
  _create_mock "$dep_bin/claude-abs" 0

  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "$dep_bin"

  # Set AUTOPILOT_CLAUDE_CMD to the absolute path.
  AUTOPILOT_CLAUDE_CMD="$dep_bin/claude-abs"
  : > "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  HOME="$fake_home"
  check_launchd_path "$TEST_PROJECT_DIR"

  # No warnings — absolute path is executable, should not produce false warning.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" != *"launchd plist PATH"* ]]
  rm -rf "$dep_bin" "$fake_home"
}

@test "check_launchd_path always returns 0 even with all deps missing" {
  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "/completely/empty/path"

  HOME="$fake_home"
  run check_launchd_path "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  rm -rf "$fake_home"
}

# --- Integration with run_preflight ---

@test "run_preflight still passes with launchd PATH warnings" {
  is_interactive() { return 0; }
  # Ensure gh mock is on PATH for the gh auth check.
  PATH="$MOCK_BIN:$OLD_PATH"

  local fake_home
  fake_home="$(_setup_fake_home)"
  _create_mock_plist "$fake_home/Library/LaunchAgents/com.autopilot.test.1.plist" \
    "$TEST_PROJECT_DIR" "/nonexistent/bin"

  HOME="$fake_home"
  run_preflight "$TEST_PROJECT_DIR"
  PATH="$OLD_PATH"

  # run_preflight should pass despite launchd warnings.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Preflight checks passed"* ]]
  [[ "$log_content" == *"launchd plist PATH"* ]]
  rm -rf "$fake_home"
}
