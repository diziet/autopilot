# Shared helpers for launchd test files.
# Provides mock creation, per-test setup, teardown, and label computation.

# Creates mock launchctl and id binaries in the given directory.
_create_launchd_mocks() {
  local mock_dir="$1"
  mkdir -p "$mock_dir"

  cat > "$mock_dir/launchctl" <<'MOCK'
#!/usr/bin/env bash
echo "launchctl $*" >> "${LAUNCHCTL_LOG:-/dev/null}"
exit 0
MOCK
  chmod +x "$mock_dir/launchctl"

  cat > "$mock_dir/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then echo "501"; fi
exit 0
MOCK
  chmod +x "$mock_dir/id"
}

# Compute the expected project name for a directory (mirrors _derive_project_name).
_expected_project_name() {
  local project_dir="$1"
  local name
  name="$(basename "$project_dir")"
  name="$(printf '%s' "$name" | tr -cs 'a-zA-Z0-9_-' '-' | sed 's/^-//;s/-$//')"
  [[ -z "$name" ]] && name="project"
  local checksum
  checksum="$(printf '%s' "$project_dir" | cksum | cut -d' ' -f1)"
  printf '%s-%04x' "$name" $(( checksum % 65536 ))
}

# Build expected label prefix for a project directory (com.autopilot.{name}).
_expected_label_prefix() {
  local project_dir="$1"
  printf 'com.autopilot.%s' "$(_expected_project_name "$project_dir")"
}

# Create an old-format plist (com.autopilot.ROLE.ACCOUNT) for migration tests.
_create_old_format_plist() {
  local agents_dir="$1" role="$2" account="$3" project_dir="$4"
  cat > "$agents_dir/com.autopilot.${role}.${account}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.autopilot.${role}.${account}</string>
  <key>WorkingDirectory</key>
  <string>${project_dir}</string>
</dict>
</plist>
PLIST
}

# Set up two test projects (alpha, beta) with their label prefixes.
_setup_two_projects() {
  PROJECT_A="$BATS_TEST_TMPDIR/alpha"
  PROJECT_B="$BATS_TEST_TMPDIR/beta"
  mkdir -p "$PROJECT_A/.autopilot/logs" "$PROJECT_B/.autopilot/logs"
  PREFIX_A="$(_expected_label_prefix "$PROJECT_A")"
  PREFIX_B="$(_expected_label_prefix "$PROJECT_B")"
}

# Per-test setup: creates project/output dirs, sets PATH/HOME/LAUNCHCTL_LOG.
_launchd_test_setup() {
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

  # Pre-compute label prefix for the default test project.
  TEST_LABEL_PREFIX="$(_expected_label_prefix "$TEST_PROJECT_DIR")"
}

# Per-test teardown: restores PATH/HOME, unsets test variables.
_launchd_test_teardown() {
  PATH="$OLD_PATH"
  HOME="$_REAL_HOME"
  unset LAUNCHCTL_LOG
  unset AUTOPILOT_CLAUDE_CMD 2>/dev/null || true
}
