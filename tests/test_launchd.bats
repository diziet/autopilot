#!/usr/bin/env bats
# Tests for launchd plist generation and variable substitution.
# Covers: plist templates, autopilot-schedule, Makefile targets.

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

  # Cache the default --generate-only output (used by ~15 tests).
  local proj="${BATS_FILE_TMPDIR}/gen_project"
  mkdir -p "$proj/.autopilot/logs"
  export _GEN_OUTPUT
  _GEN_OUTPUT="$(PATH="$_LAUNCHD_MOCK_BIN:$PATH" "$REPO_DIR/bin/autopilot-schedule" --generate-only "$proj" 2>&1)"
  export _GEN_STATUS=$?
  export _GEN_PROJECT_DIR="$proj"
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

# --- Plist generation (--generate-only, using cached output) ---

@test "generate: produces valid XML for dispatcher" {
  [ "$_GEN_STATUS" -eq 0 ]
  local dispatcher_plist
  dispatcher_plist="$(echo "$_GEN_OUTPUT" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | xmllint --noout -
}

@test "generate: substitutes project directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"$_GEN_PROJECT_DIR"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_PROJECT_DIR__"* ]]
}

@test "generate: substitutes account number" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 42 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.42"* ]]
  [[ "$output" == *"com.autopilot.reviewer.42"* ]]
  [[ "$output" != *"__AUTOPILOT_ACCOUNT__"* ]]
}

@test "generate: substitutes default interval (15)" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"<integer>15</integer>"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_START_INTERVAL__"* ]]
}

@test "generate: substitutes custom interval" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --interval 30 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<integer>30</integer>"* ]]
}

@test "generate: substitutes HOME directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"$_REAL_HOME"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_HOME__"* ]]
  [[ "$_GEN_OUTPUT" != *"__HOME__"* ]]
}

@test "generate: PATH includes HOME/.local/bin" {
  [ "$_GEN_STATUS" -eq 0 ]
  local path_value
  path_value="$(echo "$_GEN_OUTPUT" | grep -A1 '<key>PATH</key>' | tail -1)"
  [[ "$path_value" == *"${_REAL_HOME}/.local/bin"* ]]
}

@test "generate: substitutes log directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"${_GEN_PROJECT_DIR}/.autopilot/logs"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_LOG_DIR__"* ]]
}

@test "generate: substitutes bin directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_BIN_DIR__"* ]]
}

@test "generate: no substitution markers remain" {
  [ "$_GEN_STATUS" -eq 0 ]
  if echo "$_GEN_OUTPUT" | grep -qE '__AUTOPILOT_|__CLAUDE_|__HOME__'; then
    echo "Unsubstituted markers found in output:"
    echo "$_GEN_OUTPUT" | grep -E '__AUTOPILOT_|__CLAUDE_|__HOME__'
    return 1
  fi
}

@test "generate: dispatcher label includes account" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.dispatcher.3"* ]]
}

@test "generate: reviewer label includes account" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.autopilot.reviewer.3"* ]]
}

@test "generate: output contains both dispatcher and reviewer" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"autopilot-dispatch"* ]]
  [[ "$_GEN_OUTPUT" == *"autopilot-review"* ]]
}

@test "generate: dispatcher has KeepAlive false" {
  [ "$_GEN_STATUS" -eq 0 ]
  local dispatcher_plist
  dispatcher_plist="$(echo "$_GEN_OUTPUT" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | grep -q '<false/>'
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

# --- Symlink resolution ---

@test "symlink: autopilot-schedule works via symlink" {
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
