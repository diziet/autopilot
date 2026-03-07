# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source git-ops.sh (which also sources config.sh, state.sh, claude.sh).
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}
