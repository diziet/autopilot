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
  # Template provides: TEST_PROJECT_DIR with .autopilot/{state.json,logs/,locks/}.
  # See _build_global_template in test_template.bash for the template contract.
  _init_test_from_template_nogit
  TEST_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$TEST_HOOKS_DIR"
  load_config "$TEST_PROJECT_DIR"
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  # Clean up any function mocks.
  unset -f claude gh timeout 2>/dev/null || true
}
