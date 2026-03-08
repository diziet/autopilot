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

# --- Node.js detection ---

@test "deps: npm install runs when package.json exists" {
  _create_test_worktree 50
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"

  # Mock npm to record invocation.
  cat > "$TEST_MOCK_BIN/npm" << 'MOCK'
#!/usr/bin/env bash
echo "npm-install-called"
MOCK
  chmod +x "$TEST_MOCK_BIN/npm"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"npm-install-called"* ]]
}

@test "deps: yarn install runs when yarn.lock exists" {
  _create_test_worktree 51
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  touch "$WORKTREE_PATH/yarn.lock"

  cat > "$TEST_MOCK_BIN/yarn" << 'MOCK'
#!/usr/bin/env bash
echo "yarn-install-called"
MOCK
  chmod +x "$TEST_MOCK_BIN/yarn"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"yarn-install-called"* ]]
}

@test "deps: pnpm install runs when pnpm-lock.yaml exists" {
  _create_test_worktree 52
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  touch "$WORKTREE_PATH/pnpm-lock.yaml"

  cat > "$TEST_MOCK_BIN/pnpm" << 'MOCK'
#!/usr/bin/env bash
echo "pnpm-install-called"
MOCK
  chmod +x "$TEST_MOCK_BIN/pnpm"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"pnpm-install-called"* ]]
}

# --- Python detection ---

@test "deps: python creates venv before pip install with requirements.txt" {
  _create_test_worktree 53
  echo "requests==2.31.0" > "$WORKTREE_PATH/requirements.txt"

  # Mock python3 to create a fake venv with a fake pip.
  cat > "$TEST_MOCK_BIN/python3" << MOCK
#!/usr/bin/env bash
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" << 'PIP'
#!/usr/bin/env bash
echo "pip-install-called \$*"
PIP
  chmod +x "\$3/bin/pip"
  exit 0
fi
exec /usr/bin/python3 "\$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"pip-install-called"* ]]
  # Venv directory should exist.
  [ -d "$WORKTREE_PATH/.venv" ]
}

@test "deps: python creates venv with pyproject.toml" {
  _create_test_worktree 54
  printf '[project]\nname = "test"\n' > "$WORKTREE_PATH/pyproject.toml"

  cat > "$TEST_MOCK_BIN/python3" << MOCK
#!/usr/bin/env bash
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" << 'PIP'
#!/usr/bin/env bash
echo "pip-install-called \$*"
PIP
  chmod +x "\$3/bin/pip"
  exit 0
fi
exec /usr/bin/python3 "\$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"pip-install-called"* ]]
}

# --- Ruby detection ---

@test "deps: bundle install runs when Gemfile exists" {
  _create_test_worktree 55
  echo 'source "https://rubygems.org"' > "$WORKTREE_PATH/Gemfile"

  cat > "$TEST_MOCK_BIN/bundle" << 'MOCK'
#!/usr/bin/env bash
echo "bundle-install-called"
MOCK
  chmod +x "$TEST_MOCK_BIN/bundle"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"bundle-install-called"* ]]
}

# --- Go detection ---

@test "deps: go mod download runs when go.mod exists" {
  _create_test_worktree 56
  printf 'module example.com/test\ngo 1.21\n' > "$WORKTREE_PATH/go.mod"

  cat > "$TEST_MOCK_BIN/go" << 'MOCK'
#!/usr/bin/env bash
echo "go-mod-download-called"
MOCK
  chmod +x "$TEST_MOCK_BIN/go"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"go-mod-download-called"* ]]
}

# --- Custom setup command ---

@test "deps: custom setup command runs after auto-detection" {
  _create_test_worktree 57
  AUTOPILOT_WORKTREE_SETUP_CMD="echo custom-setup-ran"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"custom-setup-ran"* ]]
}

@test "deps: custom setup command runs in worktree directory" {
  _create_test_worktree 58
  AUTOPILOT_WORKTREE_SETUP_CMD="pwd"

  local output
  output="$(install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH")"
  [[ "$output" == *"$WORKTREE_PATH"* ]]
}

# --- Failure handling ---

@test "deps: install failure aborts by default" {
  _create_test_worktree 59
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"

  # Mock npm to fail.
  cat > "$TEST_MOCK_BIN/npm" << 'MOCK'
#!/usr/bin/env bash
echo "npm-error" >&2
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/npm"

  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 1 ]
}

@test "deps: install failure is soft when AUTOPILOT_WORKTREE_SETUP_OPTIONAL=true" {
  _create_test_worktree 60
  echo '{"name":"test"}' > "$WORKTREE_PATH/package.json"
  AUTOPILOT_WORKTREE_SETUP_OPTIONAL="true"

  cat > "$TEST_MOCK_BIN/npm" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/npm"

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

  # Create branch in direct mode.
  create_task_branch "$TEST_PROJECT_DIR" 63

  # Add a package.json to the project dir.
  echo '{"name":"test"}' > "$TEST_PROJECT_DIR/package.json"

  # Mock npm to fail loudly — if called, the test should detect it.
  cat > "$TEST_MOCK_BIN/npm" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: npm should not run in direct mode" >&2
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/npm"

  # In direct mode, create_task_branch does not call install_worktree_deps.
  # Verify by checking that the branch was created without error.
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-63" ]
}

# --- No project files = no install ---

@test "deps: no install when no dependency files exist" {
  _create_test_worktree 64

  # No package.json, requirements.txt, etc. — should succeed with no action.
  run install_worktree_deps "$TEST_PROJECT_DIR" "$WORKTREE_PATH"
  [ "$status" -eq 0 ]
}

# --- Integration: create_task_branch calls install_worktree_deps ---

@test "deps: create_task_branch fails when dependency install fails" {
  _enable_worktrees

  # Pre-seed a package.json in the template repo so it appears in the worktree.
  echo '{"name":"test"}' > "$TEST_PROJECT_DIR/package.json"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add package.json" -q

  # Mock npm to fail.
  cat > "$TEST_MOCK_BIN/npm" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/npm"

  run create_task_branch "$TEST_PROJECT_DIR" 65
  [ "$status" -eq 1 ]
}
