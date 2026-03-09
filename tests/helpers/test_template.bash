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
  echo "initial" > "$_TEMPLATE_GIT_DIR/README.md"
  git -C "$_TEMPLATE_GIT_DIR" add -A >/dev/null 2>&1
  git -C "$_TEMPLATE_GIT_DIR" commit -m "init" -q
  git -C "$_TEMPLATE_GIT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  # Build template mock scripts.
  mkdir -p "$_TEMPLATE_MOCK_DIR"
  _create_template_mocks

  # Cache config defaults (requires lib/config.sh sourced at file level).
  if declare -f load_config &>/dev/null; then
    _cache_config_defaults
  fi
}

# Cleans up template directories.
_cleanup_test_template() {
  rm -rf "${BATS_FILE_TMPDIR}/template_git" "${BATS_FILE_TMPDIR}/template_mocks"
}

# Copies template git repo and mocks to per-test directories.
_init_test_from_template() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"

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

  # Restore cached config defaults if available (avoids expensive load_config).
  if [[ -n "${_CACHED_CONFIG_VARS:-}" ]]; then
    _restore_config_defaults
  fi
}

# Unsets all AUTOPILOT_* env vars plus CLAUDECODE/CLAUDE_CONFIG_DIR.
_unset_autopilot_vars() {
  # Use known vars list if available (avoids env | grep | cut subprocess chain).
  if [[ -n "${_AUTOPILOT_KNOWN_VARS:-}" ]]; then
    local var_name
    for var_name in $_AUTOPILOT_KNOWN_VARS; do
      [[ -n "$var_name" ]] && unset "$var_name"
    done
  else
    local var
    while IFS= read -r var; do
      unset "$var"
    done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)
  fi
  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR
}

# Caches default config state after load_config — call once in setup_file().
_cache_config_defaults() {
  # Run load_config once with the template dir (no config files → pure defaults).
  load_config "$_TEMPLATE_GIT_DIR"

  # Snapshot all AUTOPILOT_* var values and the config sources string.
  _CACHED_CONFIG_SOURCES="$_AUTOPILOT_CONFIG_SOURCES"
  _CACHED_CONFIG_VARS=""
  local var_name
  for var_name in $_AUTOPILOT_KNOWN_VARS; do
    [[ -z "$var_name" ]] && continue
    _CACHED_CONFIG_VARS="${_CACHED_CONFIG_VARS}${var_name}=${!var_name}
"
  done
  export _CACHED_CONFIG_SOURCES _CACHED_CONFIG_VARS
}

# Restores cached config defaults — use instead of load_config in setup().
_restore_config_defaults() {
  _AUTOPILOT_CONFIG_SOURCES="$_CACHED_CONFIG_SOURCES"
  local line var_name value
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    var_name="${line%%=*}"
    value="${line#*=}"
    printf -v "$var_name" '%s' "$value"
  done <<< "$_CACHED_CONFIG_VARS"
}

# Creates standard mock scripts in the template mock directory.
_create_template_mocks() {
  # Mock gh CLI — use /bin/bash directly (faster than /usr/bin/env bash).
  cat > "${_TEMPLATE_MOCK_DIR}/gh" << 'MOCK'
#!/bin/bash
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

  # Mock claude CLI — use /bin/bash directly (faster than /usr/bin/env bash).
  cat > "${_TEMPLATE_MOCK_DIR}/claude" << 'MOCK'
#!/bin/bash
echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
MOCK
  chmod +x "${_TEMPLATE_MOCK_DIR}/claude"

  # Mock timeout — use /bin/bash directly (faster than /usr/bin/env bash).
  cat > "${_TEMPLATE_MOCK_DIR}/timeout" << 'MOCK'
#!/bin/bash
shift
exec "$@"
MOCK
  chmod +x "${_TEMPLATE_MOCK_DIR}/timeout"
}

# Installs function-based mocks (faster than PATH script mocks).
# Functions take priority over PATH scripts, avoiding fork+exec overhead.
# Call in setup() after _init_test_from_template. Tests can override individual
# functions after this call for custom behavior.
_install_function_mocks() {
  # Mock timeout — skips timeout arg, runs command directly.
  timeout() { shift; "$@"; }
  export -f timeout

  # Mock gh CLI — matches the same cases as the template script mock.
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"--json state"*) echo "MERGED" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*"headRefOid"*) echo "abc123def456" ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr merge"*) return 0 ;;
      *"pr comment"*) return 0 ;;
      *"api"*"git/ref"*) echo 'abc123' ;;
      *"api"*"pulls"*"reviews"*) echo "" ;;
      *"api"*"pulls"*"comments"*) echo "" ;;
      *"api"*"issues"*"comments"*) echo "" ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh

  # Mock claude CLI — returns valid JSON with NO_ISSUES_FOUND.
  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
}
