# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
source "$BATS_TEST_DIRNAME/../lib/git-pr.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Re-load config per test (depends on TEST_PROJECT_DIR from template init).
  load_config "$TEST_PROJECT_DIR"

  # Default to direct-checkout mode for existing tests.
  # Worktree-specific tests override this explicitly.
  AUTOPILOT_USE_WORKTREES="false"
}

