# Shared setup/teardown for git-ops test files.
# Usage: load helpers/git_ops_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
source "$BATS_TEST_DIRNAME/../lib/git-pr.sh"

# Directory for specialized git-ops templates (built once per bats run).
_GITOPS_TEMPLATE_DIR="${BATS_RUN_TMPDIR}/gitops_templates"

# Constants for test git identity.
readonly _TEST_GIT_EMAIL="test@test.com"
readonly _TEST_GIT_NAME="Test"

setup_file() {
  _create_test_template
  _create_gitops_templates
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Re-load config per test (depends on TEST_PROJECT_DIR from template init).
  load_config "$TEST_PROJECT_DIR"

  # Reset caches to prevent cross-test contamination.
  _reset_git_ops_caches

  # Default to direct-checkout mode for existing tests.
  # Worktree-specific tests override this explicitly.
  AUTOPILOT_USE_WORKTREES="false"
}

# Builds specialized git repo templates used by git-ops tests.
_create_gitops_templates() {
  # Fast path: already created by another file in this run.
  if [[ -f "${_GITOPS_TEMPLATE_DIR}/.ready" ]]; then
    return 0
  fi

  if ! mkdir "${_GITOPS_TEMPLATE_DIR}" 2>/dev/null; then
    # Another file is creating it — wait for .ready marker.
    local _wait=0
    while [[ ! -f "${_GITOPS_TEMPLATE_DIR}/.ready" ]]; do
      sleep 0.01
      _wait=$((_wait + 1))
      [[ "$_wait" -lt 500 ]] || return 1
    done
    return 0
  fi

  if ! ( _build_master_template && _build_bare_remote_template && _build_develop_clone_template ); then
    rm -rf "${_GITOPS_TEMPLATE_DIR}"
    echo "ERROR: gitops template creation failed" >&2
    return 1
  fi
  touch "${_GITOPS_TEMPLATE_DIR}/.ready"
}

# Initializes a git repo with a single commit.
_init_repo_with_commit() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  _configure_git_user "$dir"
  echo "init" > "$dir/README.md"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -q -m "Initial commit"
}

# Sets test git user identity on a repo.
_configure_git_user() {
  git -C "$1" config user.email "$_TEST_GIT_EMAIL"
  git -C "$1" config user.name "$_TEST_GIT_NAME"
}

# Template: repo with master as default branch (no main).
_build_master_template() {
  _init_repo_with_commit "${_GITOPS_TEMPLATE_DIR}/master" master
}

# Template: bare remote repo for push tests.
_build_bare_remote_template() {
  local dir="${_GITOPS_TEMPLATE_DIR}/bare"
  mkdir -p "$dir"
  git init --bare "$dir/remote.git" -q
}

# Template: bare remote with develop branch + clone (for symbolic-ref test).
_build_develop_clone_template() {
  local base="${_GITOPS_TEMPLATE_DIR}/develop"
  local bare_dir="${base}/bare"
  local clone_dir="${base}/clone"

  mkdir -p "$bare_dir"
  git init --bare "$bare_dir/remote.git" -q

  _init_repo_with_commit "${base}/seed" develop
  git -C "${base}/seed" remote add origin "$bare_dir/remote.git"
  git -C "${base}/seed" push -u origin develop >/dev/null 2>&1
  git -C "$bare_dir/remote.git" symbolic-ref HEAD refs/heads/develop

  git clone -q "$bare_dir/remote.git" "$clone_dir" 2>/dev/null
  _configure_git_user "$clone_dir"
}

