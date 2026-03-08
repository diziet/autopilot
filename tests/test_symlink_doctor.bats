#!/usr/bin/env bats
# Tests for symlink check in autopilot-doctor.

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup() {
  _setup_isolated_env

  # Need real git for symlink tests.
  local real_git
  real_git="$(command -v git)"
  ln -sf "$real_git" "$MOCK_BIN/git"

  # Also need readlink and realpath for the symlink scanner.
  local cmd
  for cmd in readlink realpath ln; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Set up a real git repo as the project.
  _setup_real_git_project "$TEST_DIR/project"
  cd "$TEST_DIR/project"
}

teardown() {
  _teardown_isolated_env
}

# Create a real git project with config files.
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

# Run autopilot-doctor with isolated PATH.
_run_doctor() {
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-doctor" "$TEST_DIR/project"
}

@test "doctor: passes symlink check when no escaping symlinks" {
  _run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] No symlinks escaping repo root"* ]]
}

@test "doctor: warns when escaping symlinks detected" {
  local external_dir
  external_dir="$(mktemp -d)"

  ln -s "$external_dir" "$TEST_DIR/project/ext_link"
  git -C "$TEST_DIR/project" add -A
  git -C "$TEST_DIR/project" commit -m "add escaping symlink" -q

  _run_doctor
  echo "$output"
  # Doctor still passes overall (symlinks are WARN not FAIL).
  [[ "$output" == *"[WARN] Symlinks that escape repo found"* ]]
  [[ "$output" == *"ext_link"* ]]
  [[ "$output" == *"AUTOPILOT_USE_WORKTREES=false"* ]]

  rm -rf "$external_dir"
}
