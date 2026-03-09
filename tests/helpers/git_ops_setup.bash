# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

load helpers/test_template

# Source modules once at file level — inherited by all test subshells.
source "${BATS_TEST_DIRNAME}/../lib/git-ops.sh"
source "${BATS_TEST_DIRNAME}/../lib/git-pr.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Default to direct-checkout mode for existing tests.
  # Worktree-specific tests override this explicitly.
  AUTOPILOT_USE_WORKTREES="false"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}
