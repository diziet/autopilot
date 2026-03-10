# Shared template helper for fast test setup.
# Creates a template git repo and mock scripts once per file (in setup_file),
# then copies them per test (in setup) instead of recreating from scratch.
#
# Usage in test files:
#   setup_file() { _create_test_template; }
#   teardown_file() { _cleanup_test_template; }
#   setup() { _init_test_from_template; ... }

# Creates a template git repo with initial commit in BATS_FILE_TMPDIR.
_create_test_template() {
  export _TEMPLATE_GIT_DIR="${BATS_FILE_TMPDIR}/template_git"
  export _TEMPLATE_MOCK_DIR="${BATS_FILE_TMPDIR}/template_mocks"

  # Build template git repo with initial commit.
  # Disable gc, fsmonitor, and advice to minimize per-operation overhead in tests.
  mkdir -p "$_TEMPLATE_GIT_DIR"
  git -C "$_TEMPLATE_GIT_DIR" init -q -b main
  git -C "$_TEMPLATE_GIT_DIR" config user.email "test@test.com"
  git -C "$_TEMPLATE_GIT_DIR" config user.name "Test"
  git -C "$_TEMPLATE_GIT_DIR" config gc.auto 0
  git -C "$_TEMPLATE_GIT_DIR" config core.fsmonitor false
  git -C "$_TEMPLATE_GIT_DIR" config advice.detachedHead false
  echo "initial" > "$_TEMPLATE_GIT_DIR/README.md"
  git -C "$_TEMPLATE_GIT_DIR" add -A >/dev/null 2>&1
  git -C "$_TEMPLATE_GIT_DIR" commit -m "init" -q
  git -C "$_TEMPLATE_GIT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  # Pre-create .autopilot state directory so tests skip init_pipeline mkdir.
  # NOTE: This JSON must match init_pipeline() in lib/state.sh — update both together.
  mkdir -p "$_TEMPLATE_GIT_DIR/.autopilot/logs" \
           "$_TEMPLATE_GIT_DIR/.autopilot/locks"
  echo '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}' \
    > "$_TEMPLATE_GIT_DIR/.autopilot/state.json"

  # Build template mock scripts.
  mkdir -p "$_TEMPLATE_MOCK_DIR"
  _create_template_mocks
}

# Cleans up template directories.
_cleanup_test_template() {
  rm -rf "${BATS_FILE_TMPDIR}/template_git" "${BATS_FILE_TMPDIR}/template_mocks"
}

# Copies template git repo and mocks to per-test directories.
_init_test_from_template() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_MOCK_BIN="$BATS_TEST_TMPDIR/mocks"
  mkdir -p "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"

  # Copy template git repo (much faster than git init + commit).
  cp -r "$_TEMPLATE_GIT_DIR/." "$TEST_PROJECT_DIR/"

  # Copy template mock scripts.
  cp "$_TEMPLATE_MOCK_DIR"/* "$TEST_MOCK_BIN/" 2>/dev/null || true

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Save original PATH for restoration in teardown (prevent accumulation).
  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"

  # Put mock bin first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

# Unsets all AUTOPILOT_* and exported _AUTOPILOT_* env vars plus CLAUDECODE/CLAUDE_CONFIG_DIR.
# Uses compgen -v for AUTOPILOT_* (all shell vars) and compgen -e for _AUTOPILOT_*
# (exported only) to avoid clearing non-exported module internals like _AUTOPILOT_KNOWN_VARS.
# Readonly _AUTOPILOT_*_LOADED source guards are skipped explicitly.
_unset_autopilot_vars() {
  local var
  for var in $(compgen -v AUTOPILOT_); do
    unset "$var"
  done
  for var in $(compgen -e _AUTOPILOT_); do
    [[ "$var" == *_LOADED ]] && continue
    unset "$var"
  done
  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR
}

# Trigger log rotation immediately (bypasses throttle in log_msg).
flush_log_rotation() {
  _rotate_log "$1"
}

# Creates standard mock scripts in the template mock directory.
_create_template_mocks() {
  # Mock gh CLI.
  cat > "${_TEMPLATE_MOCK_DIR}/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"pr view"*"--json state"*) echo "MERGED" ;;
  *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr view"*"headRefOid"*) echo "abc123def456" ;;
  *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
  *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr diff"*) echo "+added line" ;;
  *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
  *"pr merge"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"api"*"git/ref"*) echo 'abc123' ;;
  *"api"*"pulls"*"reviews"*) echo "" ;;
  *"api"*"pulls"*"comments"*) echo "" ;;
  *"api"*"issues"*"comments"*) echo "" ;;
  *"api"*) echo '[]' ;;
  *) echo "mock-gh: $*" >&2; exit 0 ;;
esac
MOCK
  chmod +x "${_TEMPLATE_MOCK_DIR}/gh"

  # Mock claude CLI.
  cat > "${_TEMPLATE_MOCK_DIR}/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
MOCK
  chmod +x "${_TEMPLATE_MOCK_DIR}/claude"

  # Mock timeout to just run the command directly.
  cat > "${_TEMPLATE_MOCK_DIR}/timeout" << 'MOCK'
#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"
MOCK
  chmod +x "${_TEMPLATE_MOCK_DIR}/timeout"
}
