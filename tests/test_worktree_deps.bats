#!/usr/bin/env bats
# Tests for worktree dependency installation (lib/worktree-deps.sh).

load helpers/git_ops_setup

# Override the default (false) set in git_ops_setup to enable worktree mode.
_enable_worktrees() {
  AUTOPILOT_USE_WORKTREES="true"
}

# Helper: create a worktree and return its path via $WORKTREE_PATH.
_create_test_worktree() {
  local task_num="${1:-50}"
  _enable_worktrees
  create_task_branch "$TEST_PROJECT_DIR" "$task_num"
  WORKTREE_PATH="$(get_task_worktree_path "$TEST_PROJECT_DIR" "$task_num")"
}

# Helper: create a mock that writes a marker file when called.
_mock_with_marker() {
  local cmd_name="$1"
  local marker_path="$2"
  cat > "$TEST_MOCK_BIN/$cmd_name" << MOCK
#!/bin/bash
echo "\$0 \$*" > "$marker_path"
MOCK
  chmod +x "$TEST_MOCK_BIN/$cmd_name"
}

# Helper: create a mock that fails.
_mock_failing() {
  local cmd_name="$1"
  cat > "$TEST_MOCK_BIN/$cmd_name" << 'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/$cmd_name"
}

# Helper: create a python3 mock that creates a fake venv with a fake pip.
_mock_python3_with_venv() {
  local venv_marker="$1"
  local pip_marker="$2"
  cat > "$TEST_MOCK_BIN/python3" << MOCK
#!/bin/bash
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
  echo "venv \$3" > "$venv_marker"
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" << PIP
#!/bin/bash
echo "pip \\\$*" > "$pip_marker"
PIP
  chmod +x "\$3/bin/pip"
  exit 0
fi
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"
}

# Helper: test a Node.js package manager detection and install.
_test_node_pm() {
  local task_num="$1"
  local lockfile="$2"
  local pm_name="$3"

  _create_test_worktree "$task_num"
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  [[ -n "$lockfile" ]] && touch "$WORKTREE_PATH/$lockfile"

  local marker="${BATS_TEST_TMPDIR}/${pm_name}_called"
  _mock_with_marker "$pm_name" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "install" "$marker"
}

# --- Node.js detection ---

@test "deps: npm install runs when package.json exists" {
  _test_node_pm 50 "" "npm"
}

@test "deps: yarn install runs when yarn.lock exists" {
  _test_node_pm 51 "yarn.lock" "yarn"
}

@test "deps: pnpm install runs when pnpm-lock.yaml exists" {
  _test_node_pm 52 "pnpm-lock.yaml" "pnpm"
}

# --- Python detection ---

@test "deps: python creates venv before pip install with requirements.txt" {
  _create_test_worktree 53
  echo "requests==2.31.0" > "$WORKTREE_PATH/requirements.txt"

  local venv_marker="${BATS_TEST_TMPDIR}/venv_called"
  local pip_marker="${BATS_TEST_TMPDIR}/pip_called"
  _mock_python3_with_venv "$venv_marker" "$pip_marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$venv_marker" ]
  [ -f "$pip_marker" ]
  grep -q "requirements.txt" "$pip_marker"
  [ -d "$WORKTREE_PATH/.venv" ]
}

@test "deps: python creates venv with pyproject.toml" {
  _create_test_worktree 54
  printf '[project]\nname = "test"\n' > "$WORKTREE_PATH/pyproject.toml"

  local venv_marker="${BATS_TEST_TMPDIR}/venv_called"
  local pip_marker="${BATS_TEST_TMPDIR}/pip_called"
  _mock_python3_with_venv "$venv_marker" "$pip_marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$venv_marker" ]
  [ -f "$pip_marker" ]
  grep -q "\-e \." "$pip_marker"
}

# --- Ruby detection ---

@test "deps: bundle install runs when Gemfile exists" {
  _create_test_worktree 55
  echo 'source "https://rubygems.org"' > "$WORKTREE_PATH/Gemfile"

  local marker="${BATS_TEST_TMPDIR}/bundle_called"
  _mock_with_marker "bundle" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "install" "$marker"
}

# --- Go detection ---

@test "deps: go mod download runs when go.mod exists" {
  _create_test_worktree 56
  printf 'module example.com/test\ngo 1.21\n' > "$WORKTREE_PATH/go.mod"

  local marker="${BATS_TEST_TMPDIR}/go_called"
  _mock_with_marker "go" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "mod download" "$marker"
}

# --- Multi-language detection ---

@test "deps: installs both node and python deps for multi-language project" {
  _create_test_worktree 70
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  echo "requests==2.31.0" > "$WORKTREE_PATH/requirements.txt"

  local npm_marker="${BATS_TEST_TMPDIR}/npm_called"
  _mock_with_marker "npm" "$npm_marker"

  local venv_marker="${BATS_TEST_TMPDIR}/venv_called"
  local pip_marker="${BATS_TEST_TMPDIR}/pip_called"
  _mock_python3_with_venv "$venv_marker" "$pip_marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$npm_marker" ]
  [ -f "$venv_marker" ]
  [ -f "$pip_marker" ]
}

# --- Custom setup command ---

@test "deps: custom setup command runs after auto-detection" {
  _create_test_worktree 57
  local marker="${BATS_TEST_TMPDIR}/custom_ran"
  AUTOPILOT_WORKTREE_SETUP_CMD="touch ${marker}"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
}

@test "deps: custom setup command runs in worktree directory" {
  _create_test_worktree 58
  local marker="${BATS_TEST_TMPDIR}/custom_pwd"
  AUTOPILOT_WORKTREE_SETUP_CMD="pwd > ${marker}"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -qF "$WORKTREE_PATH" "$marker"
}

# --- Failure handling ---

@test "deps: install failure aborts by default" {
  _create_test_worktree 59
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  _mock_failing "npm"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 1 ]
}

@test "deps: install failure is soft when AUTOPILOT_WORKTREE_SETUP_OPTIONAL=true" {
  _create_test_worktree 60
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  AUTOPILOT_WORKTREE_SETUP_OPTIONAL="true"
  _mock_failing "npm"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 0 ]
}

@test "deps: custom setup failure aborts by default" {
  _create_test_worktree 61
  AUTOPILOT_WORKTREE_SETUP_CMD="false"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 1 ]
}

@test "deps: custom setup failure is soft when optional" {
  _create_test_worktree 62
  AUTOPILOT_WORKTREE_SETUP_CMD="false"
  AUTOPILOT_WORKTREE_SETUP_OPTIONAL="true"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 0 ]
}

@test "deps: pip install failure propagates" {
  _create_test_worktree 71
  echo "requests==2.31.0" > "$WORKTREE_PATH/requirements.txt"

  # Mock python3 to create venv but with a pip that fails.
  cat > "$TEST_MOCK_BIN/python3" << 'MOCK'
#!/bin/bash
if [[ "$1" == "-m" && "$2" == "venv" ]]; then
  mkdir -p "$3/bin"
  cat > "$3/bin/pip" << 'PIP'
#!/bin/bash
exit 1
PIP
  chmod +x "$3/bin/pip"
  exit 0
fi
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 1 ]
}

# --- No install when worktrees disabled ---

@test "deps: no install when AUTOPILOT_USE_WORKTREES=false" {
  AUTOPILOT_USE_WORKTREES="false"
  create_task_branch "$TEST_PROJECT_DIR" 63

  echo '{"name":"test"}' > "$TEST_PROJECT_DIR/package.json"

  local marker="${BATS_TEST_TMPDIR}/npm_called"
  _mock_failing "npm"

  # In direct mode, create_task_branch does not call install_worktree_deps.
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-63" ]
  [ ! -f "$marker" ]
}

# --- No project files = no install ---

@test "deps: no install when no dependency files exist" {
  _create_test_worktree 64

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 0 ]
}

# --- Integration: create_task_branch calls install_worktree_deps ---

@test "deps: create_task_branch fails when dependency install fails" {
  _enable_worktrees

  echo '{"name":"test"}' > "$TEST_PROJECT_DIR/package.json"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add package.json" -q

  _mock_failing "npm"

  run create_task_branch "$TEST_PROJECT_DIR" 65
  [ "$status" -eq 1 ]
}
