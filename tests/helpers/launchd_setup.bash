# Shared helpers for launchd test files.
# Provides mock creation, per-test setup, and teardown.

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
}

# Per-test teardown: restores PATH/HOME, unsets test variables.
_launchd_test_teardown() {
  PATH="$OLD_PATH"
  HOME="$_REAL_HOME"
  unset LAUNCHCTL_LOG
  unset AUTOPILOT_CLAUDE_CMD 2>/dev/null || true
}
