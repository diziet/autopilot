# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

load helpers/test_template

# Source modules once at file level — inherited by all test subshells.
source "${BATS_TEST_DIRNAME}/../lib/git-ops.sh"
source "${BATS_TEST_DIRNAME}/../lib/git-pr.sh"

setup_file() {
  _create_test_template

  # Pre-create a master-branch template (for tests checking master vs main).
  export _TEMPLATE_MASTER_DIR="${BATS_FILE_TMPDIR}/template_master"
  mkdir -p "$_TEMPLATE_MASTER_DIR"
  git -C "$_TEMPLATE_MASTER_DIR" init -q -b master
  git -C "$_TEMPLATE_MASTER_DIR" config user.email "test@test.com"
  git -C "$_TEMPLATE_MASTER_DIR" config user.name "Test"
  echo "init" > "$_TEMPLATE_MASTER_DIR/README.md"
  git -C "$_TEMPLATE_MASTER_DIR" add -A >/dev/null 2>&1
  git -C "$_TEMPLATE_MASTER_DIR" commit -m "init" -q

  # Pre-create a bare repo template (for push/fetch tests).
  export _TEMPLATE_BARE_DIR="${BATS_FILE_TMPDIR}/template_bare"
  git init --bare "$_TEMPLATE_BARE_DIR" -q
}

teardown_file() {
  _cleanup_test_template
  rm -rf "${BATS_FILE_TMPDIR}/template_master" "${BATS_FILE_TMPDIR}/template_bare"
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

# Creates a copy of the master-branch template in a temp dir.
_copy_master_template() {
  local dir
  dir="$(mktemp -d)"
  cp -r "$_TEMPLATE_MASTER_DIR/." "$dir/"
  echo "$dir"
}

# Creates a copy of the bare repo template in a temp dir.
_copy_bare_template() {
  local dir
  dir="$(mktemp -d)"
  cp -r "$_TEMPLATE_BARE_DIR/." "$dir/"
  echo "$dir"
}
