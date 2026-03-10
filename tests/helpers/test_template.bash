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
  mkdir -p "$_TEMPLATE_GIT_DIR"
  git -C "$_TEMPLATE_GIT_DIR" init -q -b main
  git -C "$_TEMPLATE_GIT_DIR" config user.email "test@test.com"
  git -C "$_TEMPLATE_GIT_DIR" config user.name "Test"
  printf 'initial\n' > "$_TEMPLATE_GIT_DIR/README.md"
  git -C "$_TEMPLATE_GIT_DIR" add -A >/dev/null 2>&1
  git -C "$_TEMPLATE_GIT_DIR" commit -m "init" -q
  git -C "$_TEMPLATE_GIT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  # Build template mock scripts.
  mkdir -p "$_TEMPLATE_MOCK_DIR"
  _create_template_mocks
}

# Cleans up template directories.
_cleanup_test_template() {
  rm -rf "${BATS_FILE_TMPDIR}/template_git" "${BATS_FILE_TMPDIR}/template_mocks"
}

# Copies template git repo and mocks to per-test directories.
# Uses BATS_TEST_TMPDIR subdirs to avoid mktemp subprocess overhead.
_init_test_from_template() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  TEST_MOCK_BIN="${BATS_TEST_TMPDIR}/mocks"

  # Copy template git repo (much faster than git init + commit).
  cp -r "$_TEMPLATE_GIT_DIR" "$TEST_PROJECT_DIR"

  # Copy template mock scripts.
  mkdir -p "$TEST_MOCK_BIN"
  cp "$_TEMPLATE_MOCK_DIR"/* "$TEST_MOCK_BIN/" 2>/dev/null || true

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Save original PATH for restoration in teardown (prevent accumulation).
  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"

  # Put mock bin first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

# Lightweight init for tests that don't need a git repo.
# Skips cp -r of template git dir, just creates project dir and mocks.
_init_test_fast() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  TEST_MOCK_BIN="${BATS_TEST_TMPDIR}/mocks"

  mkdir -p "$TEST_PROJECT_DIR" "$TEST_MOCK_BIN"

  # Copy template mock scripts if available.
  if [[ -d "${_TEMPLATE_MOCK_DIR:-}" ]]; then
    cp "$_TEMPLATE_MOCK_DIR"/* "$TEST_MOCK_BIN/" 2>/dev/null || true
  fi

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Save original PATH for restoration in teardown (prevent accumulation).
  _ORIGINAL_PATH="${_ORIGINAL_PATH:-$PATH}"
  PATH="$_ORIGINAL_PATH"

  # Put mock bin first in PATH.
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

# Unsets all AUTOPILOT_* env vars plus CLAUDECODE/CLAUDE_CONFIG_DIR.
# Uses bash ${!prefix*} instead of env|grep subprocesses.
_unset_autopilot_vars() {
  local var
  for var in ${!AUTOPILOT_*}; do
    unset "$var"
  done
  # Also clean up source-tracking vars from config.sh
  for var in ${!_AUTOPILOT_SRC_*}; do
    unset "$var"
  done
  unset _AUTOPILOT_ENV_SNAPSHOT _AUTOPILOT_CONFIG_SOURCES
  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR
}

# Write a mock script without forking (uses printf builtin + chmod).
# Usage: _write_mock <path> <content>
_write_mock() {
  printf '%s\n' "$2" > "$1"
  chmod +x "$1"
}

# Set up a bash function mock for timeout.
# Eliminates one fork+exec per timeout invocation (~180x faster).
# Safe to use globally since the mock behavior (strip first arg, run rest)
# is the same across all test files.
_mock_timeout_fn() {
  timeout() { shift; "$@"; }
  export -f timeout
}

# Disable timeout function mock.
_unmock_timeout_fn() {
  unset -f timeout 2>/dev/null || true
}

# Creates standard mock scripts in the template mock directory.
_create_template_mocks() {
  _write_mock "${_TEMPLATE_MOCK_DIR}/gh" '#!/usr/bin/env bash
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
  *"api"*"git/ref"*) echo '"'"'{"object":{"sha":"abc123"}}'"'"' | jq -r ".object.sha" ;;
  *"api"*"pulls"*"reviews"*) echo "" ;;
  *"api"*"pulls"*"comments"*) echo "" ;;
  *"api"*"issues"*"comments"*) echo "" ;;
  *"api"*) echo "[]" ;;
  *) echo "mock-gh: $*" >&2; exit 0 ;;
esac'

  _write_mock "${_TEMPLATE_MOCK_DIR}/claude" '#!/usr/bin/env bash
echo '"'"'{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'"'"''

  _write_mock "${_TEMPLATE_MOCK_DIR}/timeout" '#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"'
}
