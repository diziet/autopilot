# Shared template helper for fast test setup.
# Creates a template git repo and mock scripts once per bats run (shared globally),
# then copies them per test (in setup) instead of recreating from scratch.
#
# Usage in test files:
#   setup_file() { _create_test_template; }
#   teardown_file() { _cleanup_test_template; }
#   setup() { _init_test_from_template; ... }
#
# For read-only tests (no writes to TEST_PROJECT_DIR):
#   setup() { _init_test_readonly; ... }

# Source config.sh at file level so _set_defaults and load_config are available
# in both setup_file() and per-test setup() scopes.
# shellcheck source=../../lib/config.sh
source "${BATS_TEST_DIRNAME}/../lib/config.sh"

# Wrap load_config with a test-only one-shot skip. When _AUTOPILOT_TEST_SKIP_LOAD
# is set, the next load_config call is a no-op (defaults already applied by
# _set_defaults in _init_test_from_template_base). Subsequent calls within
# the same test run the real implementation. Tests that re-source lib/config.sh
# (e.g., test_config.bats) replace this wrapper with the real load_config.
eval "$(echo '_real_load_config()'; declare -f load_config | tail -n +2)"
load_config() {
  if [[ "${_AUTOPILOT_TEST_SKIP_LOAD:-}" == "1" ]]; then
    unset _AUTOPILOT_TEST_SKIP_LOAD
    return 0
  fi
  _real_load_config "$@"
}

# Global template directory shared across all files in a single bats run.
_GLOBAL_TEMPLATE_DIR="${BATS_RUN_TMPDIR}/global_template"

# Initial state JSON — must match init_pipeline() in lib/state.sh.
_TEMPLATE_STATE_JSON='{"status":"pending","current_task":1,"retry_count":0,"test_fix_retries":0}'

# Copy using macOS clonefile (fast COW) with fallback to regular copy.
_fast_copy() {
  cp -rc "$1" "$2" 2>/dev/null || cp -r "$1" "$2"
}

# Creates or reuses a global template git repo with initial commit.
_create_test_template() {
  export _TEMPLATE_GIT_DIR="${_GLOBAL_TEMPLATE_DIR}/git"
  export _TEMPLATE_MOCK_DIR="${_GLOBAL_TEMPLATE_DIR}/mocks"
  export _TEMPLATE_NOGIT_DIR="${_GLOBAL_TEMPLATE_DIR}/nogit"

  # Fast path: template already exists from another file in this run.
  if [[ -f "${_GLOBAL_TEMPLATE_DIR}/.ready" ]]; then
    :
  elif mkdir "${_GLOBAL_TEMPLATE_DIR}" 2>/dev/null; then
    # We won the race — create the template.
    _build_global_template
    touch "${_GLOBAL_TEMPLATE_DIR}/.ready"
  else
    # Another file is creating it — wait for the .ready marker (timeout after 5s).
    local _wait_count=0
    while [[ ! -f "${_GLOBAL_TEMPLATE_DIR}/.ready" ]]; do
      sleep 0.01
      _wait_count=$((_wait_count + 1))
      if [[ "$_wait_count" -ge 500 ]]; then
        echo "ERROR: timed out waiting for test template creation" >&2
        return 1
      fi
    done
  fi

  # Set config defaults in setup_file scope so forked test processes inherit them.
  _set_defaults
  _AUTOPILOT_CONFIG_LOADED=1
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

  # Strip unnecessary .git files/dirs to minimize cp -r I/O per test.
  rm -rf "$_TEMPLATE_GIT_DIR/.git/hooks" \
         "$_TEMPLATE_GIT_DIR/.git/description" \
         "$_TEMPLATE_GIT_DIR/.git/info" \
         "$_TEMPLATE_GIT_DIR/.git/COMMIT_EDITMSG" \
         "$_TEMPLATE_GIT_DIR/.git/logs" \
         "$_TEMPLATE_GIT_DIR/.git/objects/info" \
         "$_TEMPLATE_GIT_DIR/.git/objects/pack" \
         "$_TEMPLATE_GIT_DIR/.git/refs/tags"

  # Pre-create .autopilot state directory.
  mkdir -p "$_TEMPLATE_GIT_DIR/.autopilot/logs" \
           "$_TEMPLATE_GIT_DIR/.autopilot/locks"
  echo "$_TEMPLATE_STATE_JSON" > "$_TEMPLATE_GIT_DIR/.autopilot/state.json"

  # Build a lightweight template without .git (for tests that don't need git).
  export _TEMPLATE_NOGIT_DIR="${_GLOBAL_TEMPLATE_DIR}/nogit"
  mkdir -p "$_TEMPLATE_NOGIT_DIR/.autopilot/logs" \
           "$_TEMPLATE_NOGIT_DIR/.autopilot/locks"
  echo "$_TEMPLATE_STATE_JSON" > "$_TEMPLATE_NOGIT_DIR/.autopilot/state.json"
  echo "initial" > "$_TEMPLATE_NOGIT_DIR/README.md"

  # Build template mock scripts.
  mkdir -p "$_TEMPLATE_MOCK_DIR"
  _create_template_mocks
}

# No-op cleanup — global template is cleaned by bats run cleanup.
_cleanup_test_template() {
  :
}

# Shared environment setup for all init modes: creates mock bin dir,
# resets AUTOPILOT_* vars, applies config defaults, and prepends mocks to PATH.
_init_test_env() {
  TEST_MOCK_BIN="$BATS_TEST_TMPDIR/mocks"
  mkdir "$TEST_MOCK_BIN"
  _unset_autopilot_vars
  _set_defaults
  _AUTOPILOT_CONFIG_LOADED=1
  _AUTOPILOT_TEST_SKIP_LOAD=1
  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"
  export PATH="${TEST_MOCK_BIN}:${_TEMPLATE_MOCK_DIR}:${PATH}"
}

# Copies src_dir to per-test directory and sets up test environment.
_init_test_from_template_base() {
  local src_dir="$1"
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  _fast_copy "$src_dir" "$TEST_PROJECT_DIR"
  _init_test_env
}

# Copies lightweight no-git template to per-test directory.
# Use this for tests that don't need git operations (faster, less I/O).
# Includes a default get_repo_slug mock; override per-test if needed.
_init_test_from_template_nogit() {
  _init_test_from_template_base "$_TEMPLATE_NOGIT_DIR"
  # Default mock for get_repo_slug (avoids needing .git/ directory).
  get_repo_slug() { echo "testowner/testrepo"; }
  export -f get_repo_slug
}

# Copies template git repo to per-test directory.
_init_test_from_template() {
  _init_test_from_template_base "$_TEMPLATE_GIT_DIR"
}

# Points TEST_PROJECT_DIR at the shared template without copying.
# Near-zero per-test I/O (only creates a mock bin directory).
# For tests that only read config, check constants, or call pure functions.
# Tests MUST NOT write to TEST_PROJECT_DIR.
_init_test_readonly() {
  TEST_PROJECT_DIR="$_TEMPLATE_NOGIT_DIR"
  _init_test_env
  # Default mock for get_repo_slug (avoids needing .git/ directory).
  get_repo_slug() { echo "testowner/testrepo"; }
  export -f get_repo_slug
}

# Unsets all AUTOPILOT_* config/runtime vars plus CLAUDECODE/CLAUDE_CONFIG_DIR.
# Uses explicit list instead of compgen for speed (~20x faster at 2000+ calls).
# SYNC: Keep in sync with _AUTOPILOT_KNOWN_VARS in lib/config.sh.
_unset_autopilot_vars() {
  unset AUTOPILOT_AUTH_FALLBACK AUTOPILOT_BRANCH_PREFIX \
    AUTOPILOT_CLAUDE_CMD AUTOPILOT_CLAUDE_FLAGS AUTOPILOT_CLAUDE_MODEL \
    AUTOPILOT_CLAUDE_OUTPUT_FORMAT AUTOPILOT_CODER_CONFIG_DIR \
    AUTOPILOT_CODEX_MIN_CONFIDENCE AUTOPILOT_CODEX_MODEL \
    AUTOPILOT_CONTEXT_FILES AUTOPILOT_ENV_SNAPSHOT AUTOPILOT_KNOWN_VARS \
    AUTOPILOT_MAX_DIFF_BYTES AUTOPILOT_MAX_LOG_LINES \
    AUTOPILOT_MAX_NETWORK_RETRIES AUTOPILOT_MAX_RETRIES \
    AUTOPILOT_MAX_REVIEWER_RETRIES AUTOPILOT_MAX_SUMMARY_ENTRY_LINES \
    AUTOPILOT_MAX_SUMMARY_LINES AUTOPILOT_MAX_TEST_FIX_RETRIES \
    AUTOPILOT_MAX_TEST_OUTPUT AUTOPILOT_REVIEWERS AUTOPILOT_REVIEWER_ACCOUNT \
    AUTOPILOT_REVIEWER_CONFIG_DIR AUTOPILOT_SOFT_PAUSE \
    AUTOPILOT_SPEC_REVIEW_CONFIG_DIR AUTOPILOT_SPEC_REVIEW_INTERVAL \
    AUTOPILOT_STALE_LOCK_MINUTES AUTOPILOT_TARGET_BRANCH \
    AUTOPILOT_TASKS_FILE AUTOPILOT_TEST_CMD AUTOPILOT_TEST_JOBS \
    AUTOPILOT_TEST_OUTPUT_TAIL AUTOPILOT_TEST_TIMEOUT \
    AUTOPILOT_TIMEOUT_AUTH_CHECK AUTOPILOT_TIMEOUT_CODER \
    AUTOPILOT_TIMEOUT_CODEX AUTOPILOT_TIMEOUT_DIAGNOSE \
    AUTOPILOT_TIMEOUT_FIXER AUTOPILOT_TIMEOUT_FIX_TESTS \
    AUTOPILOT_TIMEOUT_GH AUTOPILOT_TIMEOUT_MERGER \
    AUTOPILOT_TIMEOUT_REVIEWER AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE \
    AUTOPILOT_TIMEOUT_SPEC_REVIEW AUTOPILOT_TIMEOUT_SUMMARY \
    AUTOPILOT_TIMEOUT_TEST_GATE AUTOPILOT_USE_WORKTREES \
    AUTOPILOT_WORKTREE_SETUP_CMD AUTOPILOT_WORKTREE_SETUP_OPTIONAL \
    CLAUDECODE CLAUDE_CONFIG_DIR \
    _AUTOPILOT_CONFIG_LOADED 2>/dev/null || true
}

# Adds a .git directory to an existing nogit test dir (copies from git template).
# Call after _init_test_from_template_nogit for tests that need git operations.
_add_git_to_test_dir() {
  _fast_copy "$_TEMPLATE_GIT_DIR/.git" "$TEST_PROJECT_DIR/.git"
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
