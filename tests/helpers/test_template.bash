# Shared template helper for fast test setup.
# Creates a template git repo and mock scripts once per bats run (shared globally),
# then copies them per test (in setup) instead of recreating from scratch.
#
# Usage in test files:
#   setup_file() { _create_test_template; }
#   teardown_file() { _cleanup_test_template; }
#   setup() { _init_test_from_template; ... }

# Global template directory shared across all files in a single bats run.
_GLOBAL_TEMPLATE_DIR="${BATS_RUN_TMPDIR}/global_template"

# Creates or reuses a global template git repo with initial commit.
_create_test_template() {
  export _TEMPLATE_GIT_DIR="${_GLOBAL_TEMPLATE_DIR}/git"
  export _TEMPLATE_MOCK_DIR="${_GLOBAL_TEMPLATE_DIR}/mocks"

  # Fast path: template already exists from another file in this run.
  if [[ -f "${_GLOBAL_TEMPLATE_DIR}/.ready" ]]; then
    return 0
  fi

  # Use atomic mkdir as a lock to ensure only one file creates the template.
  if mkdir "${_GLOBAL_TEMPLATE_DIR}" 2>/dev/null; then
    # We won the race — create the template.
    _build_global_template
    touch "${_GLOBAL_TEMPLATE_DIR}/.ready"
  else
    # Another file is creating it — wait for the .ready marker.
    while [[ ! -f "${_GLOBAL_TEMPLATE_DIR}/.ready" ]]; do
      sleep 0.01
    done
  fi
}

# Builds the global template (called once per bats run).
_build_global_template() {
  mkdir -p "$_TEMPLATE_GIT_DIR"
  git -C "$_TEMPLATE_GIT_DIR" init -q -b main
  git -C "$_TEMPLATE_GIT_DIR" config user.email "test@test.com"
  git -C "$_TEMPLATE_GIT_DIR" config user.name "Test"
  echo "initial" > "$_TEMPLATE_GIT_DIR/README.md"
  git -C "$_TEMPLATE_GIT_DIR" add -A >/dev/null 2>&1
  git -C "$_TEMPLATE_GIT_DIR" commit -m "init" -q
  git -C "$_TEMPLATE_GIT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  # Strip unnecessary .git files to minimize cp -r I/O per test.
  rm -rf "$_TEMPLATE_GIT_DIR/.git/hooks" \
         "$_TEMPLATE_GIT_DIR/.git/description" \
         "$_TEMPLATE_GIT_DIR/.git/info" \
         "$_TEMPLATE_GIT_DIR/.git/COMMIT_EDITMSG" \
         "$_TEMPLATE_GIT_DIR/.git/logs"

  # Pre-create .autopilot state directory.
  # NOTE: This JSON must match init_pipeline() in lib/state.sh — update both together.
  mkdir -p "$_TEMPLATE_GIT_DIR/.autopilot/logs" \
           "$_TEMPLATE_GIT_DIR/.autopilot/locks"
  echo '{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}' \
    > "$_TEMPLATE_GIT_DIR/.autopilot/state.json"

  # Build template mock scripts.
  mkdir -p "$_TEMPLATE_MOCK_DIR"
  _create_template_mocks
}

# No-op cleanup — global template is cleaned by bats run cleanup.
_cleanup_test_template() {
  :
}

# Copies template git repo to per-test directory.
_init_test_from_template() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_MOCK_BIN="$BATS_TEST_TMPDIR/mocks"
  mkdir -p "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"

  # Copy template git repo (much faster than git init + commit).
  cp -r "$_TEMPLATE_GIT_DIR/." "$TEST_PROJECT_DIR/"

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Save original PATH for restoration in teardown (prevent accumulation).
  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"

  # Per-test mock dir first (for test-specific overrides), then shared template mocks.
  export PATH="${TEST_MOCK_BIN}:${_TEMPLATE_MOCK_DIR}:${PATH}"
}

# Unsets all AUTOPILOT_* and exported _AUTOPILOT_* env vars plus CLAUDECODE/CLAUDE_CONFIG_DIR.
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
