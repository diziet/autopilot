#!/usr/bin/env bats
# Tests for symlink detection in autopilot-init.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  UTILS_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"
  OLD_HOME="$HOME"

  # Symlink essential system commands.
  local cmd
  for cmd in bash cat chmod cp dirname echo env grep head mkdir mktemp \
             pwd readlink rm sed touch tr uname id launchctl ps wc seq \
             realpath ln; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$UTILS_BIN/$cmd"
    fi
  done

  # Create mock commands for prerequisites.
  _create_mock "claude"
  _create_mock "jq"
  _create_mock "timeout"

  # Use real git for symlink tests.
  local real_git
  real_git="$(command -v git)"
  ln -sf "$real_git" "$MOCK_BIN/git"

  # Mock gh to succeed.
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) exit 0 ;;
  *"repo create"*) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"

  # Set HOME to temp dir.
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"

  # Create a real git repo as the working directory.
  mkdir -p "$TEST_DIR/project"
  git -C "$TEST_DIR/project" init -q -b main
  git -C "$TEST_DIR/project" config user.email "test@test.com"
  git -C "$TEST_DIR/project" config user.name "Test"
  echo "init" > "$TEST_DIR/project/README.md"
  git -C "$TEST_DIR/project" add -A
  git -C "$TEST_DIR/project" commit -m "init" -q
  git -C "$TEST_DIR/project" remote add origin \
    "https://github.com/testowner/testrepo.git" 2>/dev/null || true

  cd "$TEST_DIR/project"
}

teardown() {
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

# Ensure autopilot-schedule mock exists.
_ensure_schedule_mock() {
  cat > "$MOCK_BIN/autopilot-schedule" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/autopilot-schedule"
}

# Run autopilot-init.
_run_init() {
  _ensure_schedule_mock
  PATH="$MOCK_BIN:$UTILS_BIN" run "$REPO_DIR/bin/autopilot-init" < /dev/null
}

@test "init: no escaping symlinks — does not set USE_WORKTREES" {
  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No symlinks escaping repo root"* ]]

  # autopilot.conf should not contain AUTOPILOT_USE_WORKTREES.
  if [[ -f "$TEST_DIR/project/autopilot.conf" ]]; then
    ! grep -q 'AUTOPILOT_USE_WORKTREES' "$TEST_DIR/project/autopilot.conf"
  fi
}

@test "init: escaping symlinks — auto-sets AUTOPILOT_USE_WORKTREES=false" {
  # Create an external directory and a symlink escaping the repo.
  local external_dir
  external_dir="$(mktemp -d)"
  ln -s "$external_dir" "$TEST_DIR/project/ext_data"
  git -C "$TEST_DIR/project" add -A
  git -C "$TEST_DIR/project" commit -m "add symlink" -q

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tracked symlinks that escape the repo root detected"* ]]
  [[ "$output" == *"AUTOPILOT_USE_WORKTREES=false"* ]]

  # Check autopilot.conf has the setting.
  [ -f "$TEST_DIR/project/autopilot.conf" ]
  grep -q 'AUTOPILOT_USE_WORKTREES="false"' "$TEST_DIR/project/autopilot.conf"

  rm -rf "$external_dir"
}

@test "init: skips when AUTOPILOT_USE_WORKTREES already in config" {
  # Pre-create autopilot.conf with AUTOPILOT_USE_WORKTREES already set.
  mkdir -p "$TEST_DIR/project"
  cat > "$TEST_DIR/project/autopilot.conf" << 'CONF'
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_USE_WORKTREES="true"
CONF

  # Create an escaping symlink.
  local external_dir
  external_dir="$(mktemp -d)"
  ln -s "$external_dir" "$TEST_DIR/project/ext_data"
  git -C "$TEST_DIR/project" add -A
  git -C "$TEST_DIR/project" commit -m "add symlink" -q

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"*"AUTOPILOT_USE_WORKTREES already set"* ]]

  rm -rf "$external_dir"
}
