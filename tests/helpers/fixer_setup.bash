# Shared setup/teardown for fixer test files.
# Provides: setup_file, teardown_file, setup, teardown.
# Usage: load helpers/fixer_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/fixer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  TEST_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$TEST_HOOKS_DIR"

  # Source fixer.sh (which sources config, state, claude, hooks, git-ops).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  # Clean up any function mocks.
  unset -f claude gh timeout 2>/dev/null || true
}
