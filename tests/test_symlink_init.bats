#!/usr/bin/env bats
# Tests for symlink detection in autopilot-init.

REPO_DIR="$BATS_TEST_DIRNAME/.."

# Load shared mock infrastructure.
load helpers/mock_setup

setup() {
  _setup_isolated_env
  EXTERNAL_SYMLINK_DIR=""

  # Need real git for symlink tests.
  local real_git
  real_git="$(command -v git)"
  ln -sf "$real_git" "$MOCK_BIN/git"

  # Also need seq and launchctl for init.
  local cmd
  for cmd in seq launchctl; do
    local real_path
    real_path="$(command -v "$cmd" 2>/dev/null || true)"
    [[ -n "$real_path" ]] && ln -sf "$real_path" "$UTILS_BIN/$cmd"
  done

  # Set up a real git repo as the working directory.
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
  _teardown_isolated_env
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
  _add_escaping_symlink "$TEST_DIR/project" "ext_data"

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tracked symlinks that escape the repo root detected"* ]]
  [[ "$output" == *"AUTOPILOT_USE_WORKTREES=false"* ]]

  # Check autopilot.conf has the setting.
  [ -f "$TEST_DIR/project/autopilot.conf" ]
  grep -q 'AUTOPILOT_USE_WORKTREES="false"' "$TEST_DIR/project/autopilot.conf"
}

@test "init: skips when AUTOPILOT_USE_WORKTREES already in config" {
  # Pre-create autopilot.conf with AUTOPILOT_USE_WORKTREES already set.
  cat > "$TEST_DIR/project/autopilot.conf" << 'CONF'
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_USE_WORKTREES="true"
CONF

  _add_escaping_symlink "$TEST_DIR/project" "ext_data"

  _run_init
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"*"AUTOPILOT_USE_WORKTREES already set"* ]]
}
