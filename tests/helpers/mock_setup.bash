# Shared mock setup for doctor/start tests.
# Provides isolated PATH with system command symlinks and mock CLIs.
#
# Usage in test files:
#   setup_file() { _create_mock_template; }
#   teardown_file() { _cleanup_mock_template; }
#   setup() { _setup_isolated_env; ... }
#   teardown() { _teardown_isolated_env; }

# Creates template dirs with symlinks and mocks once per test file.
_create_mock_template() {
  export _MOCK_TEMPLATE_DIR="${BATS_FILE_TMPDIR}/mock_template"
  export _UTILS_TEMPLATE_DIR="${BATS_FILE_TMPDIR}/utils_template"
  export _PROJECT_TEMPLATE_DIR="${BATS_FILE_TMPDIR}/project_template"
  mkdir -p "$_MOCK_TEMPLATE_DIR" "$_UTILS_TEMPLATE_DIR" "$_PROJECT_TEMPLATE_DIR"

  # Symlink essential system commands once into template utils dir.
  local cmd real_path
  for cmd in bash basename cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id awk wc ps ln realpath; do
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$_UTILS_TEMPLATE_DIR/$cmd"
    fi
  done

  # Create default mock scripts in template.
  _create_mock_in_dir "$_MOCK_TEMPLATE_DIR" "claude"
  _create_mock_in_dir "$_MOCK_TEMPLATE_DIR" "jq"
  _create_mock_in_dir "$_MOCK_TEMPLATE_DIR" "git"
  _create_mock_in_dir "$_MOCK_TEMPLATE_DIR" "timeout"

  # Default gh mock (auth + repo-view succeed).
  cat > "$_MOCK_TEMPLATE_DIR/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) echo "Logged in to github.com account testuser"; exit 0 ;;
  *"repo view"*) echo '{"name":"test"}'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$_MOCK_TEMPLATE_DIR/gh"

  # Default claude mock.
  cat > "$_MOCK_TEMPLATE_DIR/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"OK"}'
exit 0
MOCK
  chmod +x "$_MOCK_TEMPLATE_DIR/claude"

  # Pre-create valid project template (avoids file writes per test).
  echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$_PROJECT_TEMPLATE_DIR/autopilot.conf"
  echo '.autopilot/' > "$_PROJECT_TEMPLATE_DIR/.gitignore"
  cat > "$_PROJECT_TEMPLATE_DIR/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS
}

# Cleans up mock template directories.
_cleanup_mock_template() {
  rm -rf "${BATS_FILE_TMPDIR}/mock_template" "${BATS_FILE_TMPDIR}/utils_template" "${BATS_FILE_TMPDIR}/project_template"
}

# Set up isolated temp dirs using pre-built templates.
_setup_isolated_env() {
  TEST_DIR="$BATS_TEST_TMPDIR/testdir"
  MOCK_BIN="$BATS_TEST_TMPDIR/mockbin"
  # Use the shared template utils dir directly (read-only, never modified per test).
  UTILS_BIN="${_UTILS_TEMPLATE_DIR}"
  mkdir -p "$TEST_DIR" "$MOCK_BIN"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Fall back to creating utils from scratch if no template.
  if [[ -z "${_UTILS_TEMPLATE_DIR:-}" || ! -d "$_UTILS_TEMPLATE_DIR" ]]; then
    UTILS_BIN="$BATS_TEST_TMPDIR/utilsbin"
    mkdir -p "$UTILS_BIN"
    local cmd real_path
    for cmd in bash basename cat chmod cp dirname echo env grep head mkdir mktemp \
               pwd readlink rm sed touch tr uname id awk wc ps ln realpath; do
      real_path="$(command -v "$cmd" 2>/dev/null || true)"
      if [[ -n "$real_path" ]]; then
        ln -sf "$real_path" "$UTILS_BIN/$cmd"
      fi
    done
  fi

  if [[ -n "${_MOCK_TEMPLATE_DIR:-}" && -d "$_MOCK_TEMPLATE_DIR" ]]; then
    cp "$_MOCK_TEMPLATE_DIR"/* "$MOCK_BIN/" 2>/dev/null || true
  else
    _create_mock "claude"
    _create_mock "jq"
    _create_mock "git"
    _create_mock "timeout"
    _mock_gh 0 0
    _mock_claude 0
  fi

  # Set HOME to temp dir for account detection tests.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
}

# Clean up temp dirs and restore PATH/HOME.
_teardown_isolated_env() {
  PATH="$OLD_PATH"
  export HOME="$OLD_HOME"
}

# Create a simple mock that exits 0 in the per-test MOCK_BIN.
_create_mock() {
  cat > "$MOCK_BIN/$1" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/$1"
}

# Create a simple mock that exits 0 in a specified directory.
_create_mock_in_dir() {
  cat > "$1/$2" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$1/$2"
}

# Create a gh mock with configurable auth and repo-view exit codes.
_mock_gh() {
  local auth_exit="${1:-0}"
  local repo_exit="${2:-0}"
  cat > "$MOCK_BIN/gh" << MOCK
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) echo "Logged in to github.com account testuser"; exit $auth_exit ;;
  *"repo view"*) echo '{"name":"test"}'; exit $repo_exit ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
}

# Create a claude mock with configurable exit code.
_mock_claude() {
  local exit_code="${1:-0}"
  cat > "$MOCK_BIN/claude" << MOCK
#!/usr/bin/env bash
echo '{"result":"OK"}'
exit $exit_code
MOCK
  chmod +x "$MOCK_BIN/claude"
}

# Create a mock launchd plist referencing the project directory.
_setup_scheduler_plist() {
  local project_dir="$1"
  local agents_dir="${HOME}/Library/LaunchAgents"
  mkdir -p "$agents_dir"
  local abs_project_dir
  abs_project_dir="$(cd "$project_dir" && pwd)"
  cat > "$agents_dir/com.autopilot.dispatcher.1.plist" << PLIST
<plist><string>${abs_project_dir}</string></plist>
PLIST
}

# Set up a real git repo with config, tasks, gitignore, and initial commit.
_setup_real_git_project() {
  local project_dir="$1"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q -b main
  git -C "$project_dir" config user.email "test@test.com"
  git -C "$project_dir" config user.name "Test"

  echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$project_dir/autopilot.conf"
  echo '.autopilot/' > "$project_dir/.gitignore"
  cat > "$project_dir/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS

  git -C "$project_dir" add -A
  git -C "$project_dir" commit -m "init" -q
  git -C "$project_dir" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true
}

# Add an escaping symlink to a git project and commit it.
# Sets EXTERNAL_SYMLINK_DIR to the temp dir (caller must clean up or use teardown).
_add_escaping_symlink() {
  local project_dir="$1"
  local link_name="${2:-ext_link}"
  EXTERNAL_SYMLINK_DIR="$BATS_TEST_TMPDIR/external_symlink_${link_name}"
  mkdir -p "$EXTERNAL_SYMLINK_DIR"
  echo "external" > "$EXTERNAL_SYMLINK_DIR/data.txt"
  ln -s "$EXTERNAL_SYMLINK_DIR" "${project_dir}/${link_name}"
  git -C "$project_dir" add -A
  git -C "$project_dir" commit -m "add escaping symlink ${link_name}" -q
}

# Set up a valid project directory with config, tasks, and gitignore.
_setup_valid_project() {
  local project_dir="$1"
  if [[ -n "${_PROJECT_TEMPLATE_DIR:-}" && -d "$_PROJECT_TEMPLATE_DIR" ]]; then
    cp -r "$_PROJECT_TEMPLATE_DIR" "$project_dir"
  else
    mkdir -p "$project_dir"
    echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$project_dir/autopilot.conf"
    echo '.autopilot/' > "$project_dir/.gitignore"
    cat > "$project_dir/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS
  fi
}
