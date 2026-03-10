#!/usr/bin/env bats
# Tests for lib/testgate.sh — Test gate module.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/testgate.sh"

setup() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_GIT_DIR="$BATS_TEST_TMPDIR/git_dir"
  mkdir -p "$TEST_PROJECT_DIR" "$TEST_GIT_DIR"

  # Unset all AUTOPILOT_* env vars to start clean.
  _unset_autopilot_vars

  # Source testgate.sh (which sources config.sh, state.sh).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
}

# --- Exit Code Constants ---

@test "TESTGATE_PASS is 0" {
  [ "$TESTGATE_PASS" -eq 0 ]
}

@test "TESTGATE_FAIL is 1" {
  [ "$TESTGATE_FAIL" -eq 1 ]
}

@test "TESTGATE_SKIP is 2" {
  [ "$TESTGATE_SKIP" -eq 2 ]
}

@test "TESTGATE_ALREADY_VERIFIED is 3" {
  [ "$TESTGATE_ALREADY_VERIFIED" -eq 3 ]
}

@test "TESTGATE_ERROR is 4" {
  [ "$TESTGATE_ERROR" -eq 4 ]
}

@test "exit code constants are exported" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/testgate.sh" && echo "$TESTGATE_PASS:$TESTGATE_FAIL:$TESTGATE_SKIP:$TESTGATE_ALREADY_VERIFIED:$TESTGATE_ERROR"'
  [ "$status" -eq 0 ]
  [ "$output" = "0:1:2:3:4" ]
}

# --- SHA Flag Management ---

@test "write_hook_sha_flag creates flag file" {
  write_hook_sha_flag "$TEST_PROJECT_DIR" "abc123"
  [ -f "$TEST_PROJECT_DIR/.autopilot/test_verified_sha" ]
  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/test_verified_sha")"
  [ "$content" = "abc123" ]
}

@test "read_hook_sha_flag reads existing flag" {
  echo "def456" > "$TEST_PROJECT_DIR/.autopilot/test_verified_sha"
  local result
  result="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ "$result" = "def456" ]
}

@test "read_hook_sha_flag returns empty for missing flag" {
  local result
  result="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "clear_hook_sha_flag removes flag file" {
  echo "abc" > "$TEST_PROJECT_DIR/.autopilot/test_verified_sha"
  clear_hook_sha_flag "$TEST_PROJECT_DIR"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/test_verified_sha" ]
}

@test "is_sha_verified returns 0 when SHA matches HEAD" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local head_sha
  head_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$head_sha"
  is_sha_verified "$TEST_PROJECT_DIR"
}

@test "is_sha_verified returns 1 when SHA does not match" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  write_hook_sha_flag "$TEST_PROJECT_DIR" "stale_sha_that_doesnt_match"
  run is_sha_verified "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "is_sha_verified returns 1 when no flag exists" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run is_sha_verified "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "is_sha_verified returns 1 for non-git dir" {
  run is_sha_verified "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- Test Framework Detection: pytest ---

@test "detect_test_cmd returns AUTOPILOT_TEST_CMD when set" {
  AUTOPILOT_TEST_CMD="my-custom-test-runner --fast"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "my-custom-test-runner --fast" ]
}

@test "detect_test_cmd detects pytest via conftest.py" {
  touch "$TEST_PROJECT_DIR/conftest.py"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "detect_test_cmd detects pytest via tests/conftest.py" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/conftest.py"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "detect_test_cmd detects pytest via pyproject.toml" {
  echo '[tool.pytest]' > "$TEST_PROJECT_DIR/pyproject.toml"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "detect_test_cmd detects pytest via requirements.txt" {
  echo "pytest==7.4.0" > "$TEST_PROJECT_DIR/requirements.txt"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "detect_test_cmd detects pytest via requirements-dev.txt" {
  echo "pytest" > "$TEST_PROJECT_DIR/requirements-dev.txt"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

# --- Test Framework Detection: npm ---

@test "detect_test_cmd detects npm test" {
  cat > "$TEST_PROJECT_DIR/package.json" <<'JSON'
{"scripts": {"test": "jest"}}
JSON
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "npm test" ]
}

@test "detect_test_cmd skips npm when no test script" {
  cat > "$TEST_PROJECT_DIR/package.json" <<'JSON'
{"scripts": {"build": "webpack"}}
JSON
  run detect_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- Test Framework Detection: bats ---

@test "detect_test_cmd detects bats" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_example.bats"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "bats tests/" ]
}

# --- Test Framework Detection: make test ---

@test "detect_test_cmd detects make test" {
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MAKE'
test:
	echo "testing"
MAKE
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "make test" ]
}

@test "detect_test_cmd skips Makefile without test target" {
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MAKE'
build:
	echo "building"
MAKE
  run detect_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- Detection Priority ---

@test "detect_test_cmd prefers pytest over npm" {
  touch "$TEST_PROJECT_DIR/conftest.py"
  cat > "$TEST_PROJECT_DIR/package.json" <<'JSON'
{"scripts": {"test": "jest"}}
JSON
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "detect_test_cmd prefers npm over bats" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test.bats"
  cat > "$TEST_PROJECT_DIR/package.json" <<'JSON'
{"scripts": {"test": "mocha"}}
JSON
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "npm test" ]
}

@test "detect_test_cmd returns 1 when nothing detected" {
  run detect_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- Custom command bypasses allowlist ---

@test "custom AUTOPILOT_TEST_CMD bypasses allowlist" {
  AUTOPILOT_TEST_CMD="./run-my-weird-tests.sh --all"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "./run-my-weird-tests.sh --all" ]
}

# --- Allowlist Validation ---

@test "_is_allowed_cmd allows pytest" {
  _is_allowed_cmd "pytest"
}

@test "_is_allowed_cmd allows pytest with args" {
  _is_allowed_cmd "pytest --no-cov -x"
}

@test "_is_allowed_cmd allows npm" {
  _is_allowed_cmd "npm test"
}

@test "_is_allowed_cmd allows bats" {
  _is_allowed_cmd "bats tests/"
}

@test "_is_allowed_cmd allows make" {
  _is_allowed_cmd "make test"
}

@test "_is_allowed_cmd rejects unknown command" {
  run _is_allowed_cmd "evil-script --destroy"
  [ "$status" -eq 1 ]
}

@test "_is_allowed_cmd rejects empty command" {
  run _is_allowed_cmd ""
  [ "$status" -eq 1 ]
}

# --- _resolve_test_cmd ---

@test "_resolve_test_cmd returns ALREADY_VERIFIED when SHA matches" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local sha
  sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$sha"
  AUTOPILOT_TEST_CMD="true"
  run _resolve_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ALREADY_VERIFIED" ]
}

@test "_resolve_test_cmd returns SKIP when no test command" {
  run _resolve_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_SKIP" ]
}

@test "_resolve_test_cmd returns ERROR for disallowed auto-detected cmd" {
  _auto_detect_test_cmd() { echo "evil-cmd"; }
  run _resolve_test_cmd "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "_resolve_test_cmd echoes test command on success" {
  AUTOPILOT_TEST_CMD="pytest --fast"
  local result
  result="$(_resolve_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest --fast" ]
}

# --- Test Execution ---

@test "_run_test_cmd returns PASS for successful command" {
  run _run_test_cmd "$TEST_PROJECT_DIR" "true" 10 3>/dev/null
  [ "$status" -eq "$TESTGATE_PASS" ]
}

@test "_run_test_cmd returns FAIL for failing command" {
  run _run_test_cmd "$TEST_PROJECT_DIR" "false" 10 3>/dev/null
  [ "$status" -eq "$TESTGATE_FAIL" ]
}

@test "_run_test_cmd captures stdout" {
  local output
  output="$(_run_test_cmd "$TEST_PROJECT_DIR" "echo hello-tests" 10 3>/dev/null)"
  [[ "$output" == *"hello-tests"* ]]
}

@test "_run_test_cmd writes raw exit code to fd 3" {
  local raw_file
  raw_file="$BATS_TEST_TMPDIR/raw_file"
  _run_test_cmd "$TEST_PROJECT_DIR" "exit 42" 10 3>"$raw_file" || true
  local raw_exit
  raw_exit="$(cat "$raw_file")"
  [ "$raw_exit" = "42" ]
}

@test "_run_test_cmd uses positional args for safe path handling" {
  # Verify the command runs in the correct directory.
  local output
  output="$(_run_test_cmd "$TEST_PROJECT_DIR" "pwd" 10 3>/dev/null)"
  [[ "$output" == *"$TEST_PROJECT_DIR"* ]]
}

# --- run_test_gate ---

@test "run_test_gate returns SKIP when no test command" {
  run run_test_gate "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_SKIP" ]
}

@test "run_test_gate returns PASS when tests succeed" {
  AUTOPILOT_TEST_CMD="true"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run run_test_gate "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_PASS" ]
}

@test "run_test_gate returns FAIL when tests fail" {
  AUTOPILOT_TEST_CMD="false"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run run_test_gate "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_FAIL" ]
}

@test "run_test_gate returns ALREADY_VERIFIED when SHA matches" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local sha
  sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$sha"
  AUTOPILOT_TEST_CMD="true"
  run run_test_gate "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ALREADY_VERIFIED" ]
}

@test "run_test_gate writes SHA flag on pass" {
  AUTOPILOT_TEST_CMD="true"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local head_sha
  head_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  run_test_gate "$TEST_PROJECT_DIR" || true
  local flag_sha
  flag_sha="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ "$flag_sha" = "$head_sha" ]
}

@test "run_test_gate logs PASSED on success" {
  AUTOPILOT_TEST_CMD="true"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run_test_gate "$TEST_PROJECT_DIR" || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Test gate PASSED"* ]]
}

@test "run_test_gate logs FAILED with raw exit code" {
  AUTOPILOT_TEST_CMD="exit 42"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run_test_gate "$TEST_PROJECT_DIR" || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Test gate FAILED (raw_exit=42)"* ]]
}

@test "run_test_gate rejects auto-detected cmd not on allowlist" {
  _auto_detect_test_cmd() { echo "evil-cmd"; }
  AUTOPILOT_TEST_CMD=""
  run run_test_gate "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

# --- Worktree Management ---

@test "create_test_worktree creates a detached worktree" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local worktree_dir
  worktree_dir="$(create_test_worktree "$TEST_PROJECT_DIR" "HEAD")"
  [ -d "$worktree_dir" ]
  [ -f "$worktree_dir/.git" ]
  remove_test_worktree "$TEST_PROJECT_DIR" "$worktree_dir"
}

@test "create_test_worktree fails for invalid branch" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run create_test_worktree "$TEST_PROJECT_DIR" "nonexistent-branch"
  [ "$status" -eq 1 ]
}

@test "remove_test_worktree is safe for missing dir" {
  run remove_test_worktree "$TEST_PROJECT_DIR" ""
  [ "$status" -eq 0 ]
}

@test "remove_test_worktree cleans up worktree" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local worktree_dir
  worktree_dir="$(create_test_worktree "$TEST_PROJECT_DIR" "HEAD")"
  [ -d "$worktree_dir" ]
  remove_test_worktree "$TEST_PROJECT_DIR" "$worktree_dir"
  [ ! -d "$worktree_dir" ]
}

# --- Background Test Gate ---

@test "run_test_gate_background writes SKIP when no test cmd" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local result_file
  result_file="$(run_test_gate_background "$TEST_PROJECT_DIR" "HEAD")"
  [ -f "$result_file" ]
  local result
  result="$(cat "$result_file")"
  [ "$result" = "$TESTGATE_SKIP" ]
}

@test "run_test_gate_background writes ALREADY_VERIFIED when SHA matches" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local sha
  sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  write_hook_sha_flag "$TEST_PROJECT_DIR" "$sha"
  AUTOPILOT_TEST_CMD="true"
  local result_file
  result_file="$(run_test_gate_background "$TEST_PROJECT_DIR" "HEAD")"
  local result
  result="$(cat "$result_file")"
  [ "$result" = "$TESTGATE_ALREADY_VERIFIED" ]
}

@test "run_test_gate_background runs passing tests in worktree" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  AUTOPILOT_TEST_CMD="true"
  AUTOPILOT_TIMEOUT_TEST_GATE=30
  local result_file
  result_file="$(run_test_gate_background "$TEST_PROJECT_DIR" "HEAD")"
  # Wait for background process to complete.
  wait
  [ -f "$result_file" ]
  local result
  result="$(cat "$result_file")"
  [ "$result" = "0" ]
  # SHA flag should be set after passing tests.
  local head_sha flag_sha
  head_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  flag_sha="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ "$flag_sha" = "$head_sha" ]
}

@test "run_test_gate_background runs failing tests in worktree" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  AUTOPILOT_TEST_CMD="false"
  AUTOPILOT_TIMEOUT_TEST_GATE=30
  local result_file
  result_file="$(run_test_gate_background "$TEST_PROJECT_DIR" "HEAD")"
  wait
  [ -f "$result_file" ]
  local result
  result="$(cat "$result_file")"
  [ "$result" = "1" ]
  # SHA flag should NOT be set after failing tests.
  local flag_sha
  flag_sha="$(read_hook_sha_flag "$TEST_PROJECT_DIR")"
  [ -z "$flag_sha" ]
}

@test "run_test_gate_background cleans up worktree after completion" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  AUTOPILOT_TEST_CMD="true"
  AUTOPILOT_TIMEOUT_TEST_GATE=30
  run_test_gate_background "$TEST_PROJECT_DIR" "HEAD" > /dev/null
  wait
  # Worktree directory should be cleaned up.
  local worktrees
  worktrees="$(find "$TEST_PROJECT_DIR/.autopilot/worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "$worktrees" -le 1 ]
}

@test "run_test_gate_background captures test output to log file" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  AUTOPILOT_TEST_CMD="echo test-output-marker"
  AUTOPILOT_TIMEOUT_TEST_GATE=30
  run_test_gate_background "$TEST_PROJECT_DIR" "HEAD" > /dev/null
  wait
  local output_log="$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"
  [ -f "$output_log" ]
  local content
  content="$(cat "$output_log")"
  [[ "$content" == *"test-output-marker"* ]]
}

@test "run_test_gate_background clears stale result file" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  # Write a stale PASS result.
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  AUTOPILOT_TEST_CMD="false"
  AUTOPILOT_TIMEOUT_TEST_GATE=30
  local result_file
  result_file="$(run_test_gate_background "$TEST_PROJECT_DIR" "HEAD")"
  wait
  local result
  result="$(cat "$result_file")"
  # Should be FAIL (1), not stale PASS (0).
  [ "$result" = "1" ]
}

# --- read_test_gate_result ---

@test "read_test_gate_result returns PASS from result file" {
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  read_test_gate_result "$TEST_PROJECT_DIR"
}

@test "read_test_gate_result returns FAIL from result file" {
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "read_test_gate_result returns ERROR for missing file" {
  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "read_test_gate_result returns ERROR for empty file" {
  touch "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "read_test_gate_result returns ERROR for non-numeric content" {
  echo "corrupted" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"
  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

# --- Venv Detection (_build_test_shell_cmd) ---

@test "_build_test_shell_cmd prepends .venv activation when .venv exists" {
  mkdir -p "$TEST_PROJECT_DIR/.venv/bin"
  touch "$TEST_PROJECT_DIR/.venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$TEST_PROJECT_DIR" "pytest -p no:cov")"
  [ "$result" = "source '${TEST_PROJECT_DIR}/.venv/bin/activate' && pytest -p no:cov" ]
}

@test "_build_test_shell_cmd prepends venv activation when venv exists" {
  mkdir -p "$TEST_PROJECT_DIR/venv/bin"
  touch "$TEST_PROJECT_DIR/venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$TEST_PROJECT_DIR" "pytest -p no:cov")"
  [ "$result" = "source '${TEST_PROJECT_DIR}/venv/bin/activate' && pytest -p no:cov" ]
}

@test "_build_test_shell_cmd prefers .venv over venv" {
  mkdir -p "$TEST_PROJECT_DIR/.venv/bin"
  touch "$TEST_PROJECT_DIR/.venv/bin/activate"
  mkdir -p "$TEST_PROJECT_DIR/venv/bin"
  touch "$TEST_PROJECT_DIR/venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$TEST_PROJECT_DIR" "pytest")"
  [ "$result" = "source '${TEST_PROJECT_DIR}/.venv/bin/activate' && pytest" ]
}

@test "_build_test_shell_cmd returns command as-is when no venv" {
  local result
  result="$(_build_test_shell_cmd "$TEST_PROJECT_DIR" "pytest -p no:cov")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "_build_test_shell_cmd works with non-pytest commands" {
  mkdir -p "$TEST_PROJECT_DIR/.venv/bin"
  touch "$TEST_PROJECT_DIR/.venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$TEST_PROJECT_DIR" "make test")"
  [ "$result" = "source '${TEST_PROJECT_DIR}/.venv/bin/activate' && make test" ]
}

@test "_build_test_shell_cmd falls back to orig_project_dir venv" {
  local worktree_dir
  worktree_dir="$BATS_TEST_TMPDIR/worktree_dir"
  mkdir -p "$worktree_dir"
  mkdir -p "$TEST_PROJECT_DIR/.venv/bin"
  touch "$TEST_PROJECT_DIR/.venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$worktree_dir" "pytest" "$TEST_PROJECT_DIR")"
  [ "$result" = "source '${TEST_PROJECT_DIR}/.venv/bin/activate' && pytest" ]
}

@test "_build_test_shell_cmd prefers work_dir venv over orig_project_dir" {
  local worktree_dir
  worktree_dir="$BATS_TEST_TMPDIR/worktree_dir2"
  mkdir -p "$worktree_dir/.venv/bin"
  touch "$worktree_dir/.venv/bin/activate"
  mkdir -p "$TEST_PROJECT_DIR/.venv/bin"
  touch "$TEST_PROJECT_DIR/.venv/bin/activate"
  local result
  result="$(_build_test_shell_cmd "$worktree_dir" "pytest" "$TEST_PROJECT_DIR")"
  [ "$result" = "source '${worktree_dir}/.venv/bin/activate' && pytest" ]
}

@test "_build_test_shell_cmd returns bare cmd when neither dir has venv" {
  local worktree_dir
  worktree_dir="$BATS_TEST_TMPDIR/worktree_dir3"
  mkdir -p "$worktree_dir"
  local result
  result="$(_build_test_shell_cmd "$worktree_dir" "pytest" "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest" ]
}

# --- -p no:cov on auto-detected pytest ---

@test "auto-detected pytest disables coverage plugin" {
  touch "$TEST_PROJECT_DIR/conftest.py"
  unset AUTOPILOT_TEST_CMD
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -p no:cov" ]
}

@test "explicit AUTOPILOT_TEST_CMD=pytest does NOT get -p no:cov" {
  AUTOPILOT_TEST_CMD="pytest"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest" ]
}

@test "explicit AUTOPILOT_TEST_CMD=pytest -x does NOT get -p no:cov" {
  AUTOPILOT_TEST_CMD="pytest -x"
  local result
  result="$(detect_test_cmd "$TEST_PROJECT_DIR")"
  [ "$result" = "pytest -x" ]
}

# --- _extract_failing_tests ---

@test "_extract_failing_tests extracts 'not ok' lines" {
  local tap_output
  tap_output="$(printf '%s\n' \
    'ok 1 test_passes' \
    'ok 2 test_also_passes' \
    'not ok 3 test_fails_here' \
    '#   expected 0 got 1' \
    'ok 4 test_passes_again' \
    'not ok 5 test_also_fails' \
    '#   assertion error' \
    'ok 6 final_pass')"
  local result
  result="$(_extract_failing_tests "$tap_output")"
  [[ "$result" == *"not ok 3 test_fails_here"* ]]
  [[ "$result" == *"not ok 5 test_also_fails"* ]]
}

@test "_extract_failing_tests includes assertion detail lines" {
  local tap_output
  tap_output="$(printf '%s\n' \
    'ok 1 test_passes' \
    'not ok 2 test_fails' \
    '#   expected true got false' \
    'ok 3 test_passes_again')"
  local result
  result="$(_extract_failing_tests "$tap_output")"
  [[ "$result" == *"#   expected true got false"* ]]
}

@test "_extract_failing_tests returns empty for all-passing output" {
  local tap_output
  tap_output="$(printf '%s\n' \
    'ok 1 test_a' \
    'ok 2 test_b' \
    'ok 3 test_c')"
  local result
  result="$(_extract_failing_tests "$tap_output")"
  [ -z "$result" ]
}

# --- _log_failing_tests ---

@test "_log_failing_tests logs failing test names on failure" {
  local tap_output
  tap_output="$(printf '%s\n' \
    'ok 1 test_passes' \
    'not ok 2 test_fails_badly' \
    '#   got error code 42' \
    'ok 3 test_ok')"
  _log_failing_tests "$TEST_PROJECT_DIR" "$tap_output"
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Failing tests:"* ]]
  [[ "$log" == *"not ok 2 test_fails_badly"* ]]
  [[ "$log" == *"got error code 42"* ]]
}

@test "_log_failing_tests does not log when all tests pass" {
  local tap_output
  tap_output="$(printf '%s\n' 'ok 1 test_a' 'ok 2 test_b')"
  _log_failing_tests "$TEST_PROJECT_DIR" "$tap_output"
  if [ -f "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" ]; then
    local log
    log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
    [[ "$log" != *"Failing tests:"* ]]
  fi
}

# --- _handle_test_gate_result logs failing tests ---

# --- Timer and Summary Logging ---

@test "run_test_gate logs TIMER line on pass" {
  AUTOPILOT_TEST_CMD="true"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run_test_gate "$TEST_PROJECT_DIR" || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TIMER: test gate ("*"s)"* ]]
}

@test "run_test_gate logs TIMER line on fail" {
  AUTOPILOT_TEST_CMD="false"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run_test_gate "$TEST_PROJECT_DIR" || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TIMER: test gate ("*"s)"* ]]
}

@test "run_test_gate logs TEST_GATE summary with TAP output" {
  AUTOPILOT_TEST_CMD="printf 'ok 1 test_a\nok 2 test_b\nnot ok 3 test_c\n'"
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  run_test_gate "$TEST_PROJECT_DIR" || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TEST_GATE: Tests: 3 total, 2 passed, 1 failed"* ]]
}

@test "_log_test_gate_summary logs summary from output file" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  printf 'ok 1 first\nok 2 second\n' > "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"
  local start_epoch
  start_epoch="$(date +%s)"
  _log_test_gate_summary "$TEST_PROJECT_DIR" 0 "$start_epoch" 300
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TEST_GATE: Tests: 2 total, 2 passed, 0 failed"* ]]
}

@test "_handle_test_gate_result logs not-ok lines before tail output" {
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" commit --allow-empty -m "init" -q
  local tap_output
  tap_output="$(printf '%s\n' \
    'ok 1 test_first' \
    'not ok 2 test_broken' \
    '#   assertion failed' \
    'ok 3 test_last')"
  run _handle_test_gate_result "$TEST_PROJECT_DIR" 1 "$tap_output" 1
  [ "$status" -eq "$TESTGATE_FAIL" ]
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"Failing tests:"* ]]
  [[ "$log" == *"not ok 2 test_broken"* ]]
  [[ "$log" == *"assertion failed"* ]]
}
