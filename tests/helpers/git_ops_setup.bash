# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset CLAUDECODE to avoid interference.
  unset CLAUDECODE

  # Source git-ops.sh (which also sources config.sh, state.sh, claude.sh).
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize git repo for tests that need it.
  _init_test_repo
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# Helper: initialize a test git repo with an initial commit.
_init_test_repo() {
  git -C "$TEST_PROJECT_DIR" init -b main >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"
  echo "initial" > "$TEST_PROJECT_DIR/README.md"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Initial commit" >/dev/null 2>&1
}
