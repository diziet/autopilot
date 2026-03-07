#!/usr/bin/env bats
# Tests for bin/autopilot-doctor — project setup validation.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  MOCK_BIN="$TEST_MOCK_BIN"

  # Create required project files for a passing setup.
  echo "# Tasks" > "$TEST_PROJECT_DIR/tasks.md"
  echo "## Task 1: Do something" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/tasks.md"

  cat > "$TEST_PROJECT_DIR/autopilot.conf" << 'CONF'
# Test config
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
CONF

  echo '.autopilot/' > "$TEST_PROJECT_DIR/.gitignore"

  # Create mock gh with auth and repo view support.
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) echo "testuser" ;;
  *"auth status"*) exit 0 ;;
  *"repo view"*) echo '{"name":"testrepo"}' ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"

  # Create mock claude that succeeds on smoke test.
  cat > "$MOCK_BIN/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"result":"OK"}'
MOCK
  chmod +x "$MOCK_BIN/claude"

  # Ensure jq, git, timeout are on PATH.
  for cmd in jq git timeout; do
    if [[ ! -f "$MOCK_BIN/$cmd" ]]; then
      cat > "$MOCK_BIN/$cmd" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
      chmod +x "$MOCK_BIN/$cmd"
    fi
  done

  DOCTOR="$BATS_TEST_DIRNAME/../bin/autopilot-doctor"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR" "$MOCK_BIN"
}

# --- All checks pass ---

@test "doctor: all checks pass returns exit 0" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"All checks passed"* ]]
}

@test "doctor: shows PASS for each prerequisite" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] claude CLI found at"* ]]
  [[ "$output" == *"[PASS] gh CLI found at"* ]]
  [[ "$output" == *"[PASS] jq CLI found at"* ]]
  [[ "$output" == *"[PASS] git CLI found at"* ]]
  [[ "$output" == *"[PASS] timeout CLI found at"* ]]
}

@test "doctor: shows PASS for gh auth" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] gh authenticated as testuser"* ]]
}

@test "doctor: shows PASS for tasks file" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] Tasks file found with task headings"* ]]
}

@test "doctor: shows PASS for config" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] autopilot.conf is valid"* ]]
}

@test "doctor: shows PASS for gitignore" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] .autopilot/ is in .gitignore"* ]]
}

# --- Prerequisite failures ---

@test "doctor: FAIL when claude not found" {
  rm -f "$MOCK_BIN/claude"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] claude not found"* ]]
}

@test "doctor: FAIL when gh not found" {
  rm -f "$MOCK_BIN/gh"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] gh not found"* ]]
}

@test "doctor: FAIL when jq not found" {
  rm -f "$MOCK_BIN/jq"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] jq not found"* ]]
}

@test "doctor: FAIL when git not found" {
  rm -f "$MOCK_BIN/git"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] git not found"* ]]
}

@test "doctor: FAIL when timeout not found" {
  rm -f "$MOCK_BIN/timeout"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] timeout not found"* ]]
}

# --- gh auth failure ---

@test "doctor: FAIL when gh auth fails" {
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) exit 1 ;;
  *"auth status"*) exit 1 ;;
  *"repo view"*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] gh not authenticated — run: gh auth login"* ]]
}

# --- Tasks file failures ---

@test "doctor: FAIL when tasks file not found" {
  rm -f "$TEST_PROJECT_DIR/tasks.md"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] No tasks file found — run: autopilot init"* ]]
}

@test "doctor: FAIL when tasks file has no task headings" {
  echo "# Just a heading" > "$TEST_PROJECT_DIR/tasks.md"
  echo "No tasks here" >> "$TEST_PROJECT_DIR/tasks.md"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] Tasks file found but has no ## Task headings"* ]]
}

# --- Config failures ---

@test "doctor: FAIL when autopilot.conf not found" {
  rm -f "$TEST_PROJECT_DIR/autopilot.conf"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] autopilot.conf not found — run: autopilot init"* ]]
}

@test "doctor: FAIL when autopilot.conf has bad syntax" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" << 'CONF'
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
INVALID_LINE=bad
CONF
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] autopilot.conf has unparseable lines"* ]]
}

# --- Gitignore failures ---

@test "doctor: FAIL when .gitignore not found" {
  rm -f "$TEST_PROJECT_DIR/.gitignore"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] .gitignore not found"* ]]
}

@test "doctor: FAIL when .autopilot/ not in .gitignore" {
  echo "node_modules/" > "$TEST_PROJECT_DIR/.gitignore"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] .autopilot/ not in .gitignore"* ]]
}

# --- Remote failure ---

@test "doctor: FAIL when GitHub remote not reachable" {
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) echo "testuser" ;;
  *"auth status"*) exit 0 ;;
  *"repo view"*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] GitHub remote not reachable"* ]]
}

# --- Account directory checks ---

@test "doctor: FAIL when coder config dir configured but missing" {
  export AUTOPILOT_CODER_CONFIG_DIR="/nonexistent/path"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] Coder config dir not found"* ]]
}

@test "doctor: FAIL when reviewer config dir configured but missing" {
  export AUTOPILOT_REVIEWER_CONFIG_DIR="/nonexistent/path"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] Reviewer config dir not found"* ]]
}

@test "doctor: PASS when account dirs exist" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  export AUTOPILOT_CODER_CONFIG_DIR="$tmpdir"
  export AUTOPILOT_REVIEWER_CONFIG_DIR="$tmpdir"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] Coder config dir exists"* ]]
  [[ "$output" == *"[PASS] Reviewer config dir exists"* ]]
  rm -rf "$tmpdir"
}

# --- Claude smoke test ---

@test "doctor: PASS for Claude smoke test with default config" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] Claude default config — API responding"* ]]
}

@test "doctor: WARN about single account" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[WARN] Only one Claude account detected"* ]]
}

@test "doctor: FAIL when Claude smoke test fails" {
  cat > "$MOCK_BIN/claude" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[FAIL] Claude default config — API not responding"* ]]
}

# --- Help flag ---

@test "doctor: --help shows usage" {
  run "$DOCTOR" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Usage: autopilot-doctor"* ]]
}

@test "doctor: -h shows usage" {
  run "$DOCTOR" -h
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Usage: autopilot-doctor"* ]]
}

@test "doctor: unknown option fails" {
  run "$DOCTOR" --unknown
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"Error: unknown option"* ]]
}

# --- Permissions flag ---

@test "doctor: shows PASS for dangerously-skip-permissions flag" {
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$output" == *"[PASS] AUTOPILOT_CLAUDE_FLAGS includes --dangerously-skip-permissions"* ]]
}

# --- Multiple failures ---

@test "doctor: reports count of failures" {
  rm -f "$MOCK_BIN/claude"
  rm -f "$TEST_PROJECT_DIR/autopilot.conf"
  run "$DOCTOR" "$TEST_PROJECT_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"check(s) failed"* ]]
}
