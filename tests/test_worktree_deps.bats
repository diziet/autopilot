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
#!/usr/bin/env bash
echo "\$0 \$*" > "$marker_path"
MOCK
  chmod +x "$TEST_MOCK_BIN/$cmd_name"
}

# Helper: create a mock that fails.
_mock_failing() {
  local cmd_name="$1"
  cat > "$TEST_MOCK_BIN/$cmd_name" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/$cmd_name"
}

# --- Node.js detection ---

@test "deps: npm install runs when package.json exists" {
  _create_test_worktree 50
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"

  local marker="${BATS_TEST_TMPDIR}/npm_called"
  _mock_with_marker "npm" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "install" "$marker"
}

@test "deps: yarn install runs when yarn.lock exists" {
  _create_test_worktree 51
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  touch "$WORKTREE_PATH/yarn.lock"

  local marker="${BATS_TEST_TMPDIR}/yarn_called"
  _mock_with_marker "yarn" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "install" "$marker"
}

@test "deps: pnpm install runs when pnpm-lock.yaml exists" {
  _create_test_worktree 52
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  touch "$WORKTREE_PATH/pnpm-lock.yaml"

  local marker="${BATS_TEST_TMPDIR}/pnpm_called"
  _mock_with_marker "pnpm" "$marker"

  install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ -f "$marker" ]
  grep -q "install" "$marker"
}

# --- Python detection ---

@test "deps: python creates venv before pip install with requirements.txt" {
  _create_test_worktree 53
  echo "requests==2.31.0" > "$WORKTREE_PATH/requirements.txt"

  local venv_marker="${BATS_TEST_TMPDIR}/venv_called"
  local pip_marker="${BATS_TEST_TMPDIR}/pip_called"

  # Mock python3 to create a fake venv with a fake pip that writes a marker.
  cat > "$TEST_MOCK_BIN/python3" << MOCK
#!/usr/bin/env bash
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
  echo "venv \$3" > "$venv_marker"
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" << PIP
#!/usr/bin/env bash
echo "pip \\\$*" > "$pip_marker"
PIP
  chmod +x "\$3/bin/pip"
  exit 0
fi
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"

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

  cat > "$TEST_MOCK_BIN/python3" << MOCK
#!/usr/bin/env bash
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
  echo "venv \$3" > "$venv_marker"
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" << PIP
#!/usr/bin/env bash
echo "pip \\\$*" > "$pip_marker"
PIP
  chmod +x "\$3/bin/pip"
  exit 0
fi
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"

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
