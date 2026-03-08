# Shared mock setup for doctor/start tests.
# Provides isolated PATH with system command symlinks and mock CLIs.
#
# Usage in test files:
#   setup() { _setup_isolated_env; ... }
#   teardown() { _teardown_isolated_env; }

# Set up isolated temp dirs, system command symlinks, and default mocks.
_setup_isolated_env() {
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  UTILS_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Symlink essential system commands into an isolated utils dir.
  local cmd
  for cmd in bash basename cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id awk wc ps ln realpath; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Create mock commands for all prerequisites.
  _create_mock "claude"
  _create_mock "jq"
  _create_mock "git"
  _create_mock "timeout"

  # Mock gh and claude to succeed by default.
  _mock_gh 0 0
  _mock_claude 0

  # Set HOME to temp dir for account detection tests.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
}

# Clean up temp dirs and restore PATH/HOME.
_teardown_isolated_env() {
  PATH="$OLD_PATH"
  export HOME="$OLD_HOME"
  rm -rf "$TEST_DIR" "$MOCK_BIN" "$UTILS_BIN"
}

# Create a simple mock that exits 0.
_create_mock() {
  cat > "$MOCK_BIN/$1" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/$1"
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
  EXTERNAL_SYMLINK_DIR="$(mktemp -d)"
  echo "external" > "$EXTERNAL_SYMLINK_DIR/data.txt"
  ln -s "$EXTERNAL_SYMLINK_DIR" "${project_dir}/${link_name}"
  git -C "$project_dir" add -A
  git -C "$project_dir" commit -m "add escaping symlink ${link_name}" -q
}

# Set up a valid project directory with config, tasks, and gitignore.
_setup_valid_project() {
  local project_dir="$1"
  mkdir -p "$project_dir"
  echo 'AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"' > "$project_dir/autopilot.conf"
  echo '.autopilot/' > "$project_dir/.gitignore"
  cat > "$project_dir/tasks.md" << 'TASKS'
# Tasks

## Task 1: Sample task

Do something.
TASKS
}
