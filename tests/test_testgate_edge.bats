#!/usr/bin/env bats
# Edge case tests for lib/testgate.sh — bats detection, resolve result logging,
# test gate result handling, result file management, and test command detection.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source testgate.sh (which sources config, state, twophase).
  source "$BATS_TEST_DIRNAME/../lib/testgate.sh"

  # Initialize state dir.
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- _is_bats_test_cmd ---

@test "_is_bats_test_cmd matches 'bats tests/'" {
  run _is_bats_test_cmd "bats tests/"
  [ "$status" -eq 0 ]
}

@test "_is_bats_test_cmd matches bare 'bats'" {
  run _is_bats_test_cmd "bats"
  [ "$status" -eq 0 ]
}

@test "_is_bats_test_cmd matches 'bats tests/*.bats'" {
  run _is_bats_test_cmd "bats tests/*.bats"
  [ "$status" -eq 0 ]
}

@test "_is_bats_test_cmd rejects 'pytest'" {
  run _is_bats_test_cmd "pytest"
  [ "$status" -eq 1 ]
}

@test "_is_bats_test_cmd rejects 'npm test'" {
  run _is_bats_test_cmd "npm test"
  [ "$status" -eq 1 ]
}

@test "_is_bats_test_cmd rejects 'make bats'" {
  run _is_bats_test_cmd "make bats"
  [ "$status" -eq 1 ]
}

@test "_is_bats_test_cmd rejects empty string" {
  run _is_bats_test_cmd ""
  [ "$status" -eq 1 ]
}

# --- _log_resolve_result ---

@test "_log_resolve_result logs ALREADY_VERIFIED" {
  _log_resolve_result "$TEST_PROJECT_DIR" "$TESTGATE_ALREADY_VERIFIED"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"already verified"* ]]
}

@test "_log_resolve_result logs SKIP" {
  _log_resolve_result "$TEST_PROJECT_DIR" "$TESTGATE_SKIP"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"No test command detected"* ]]
}

@test "_log_resolve_result logs ERROR for disallowed" {
  _log_resolve_result "$TEST_PROJECT_DIR" "$TESTGATE_ERROR"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"not on allowlist"* ]]
}

@test "_log_resolve_result includes context suffix" {
  _log_resolve_result "$TEST_PROJECT_DIR" "$TESTGATE_SKIP" " background gate"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"background gate"* ]]
}

# --- _handle_test_gate_result ---

@test "_handle_test_gate_result returns PASS and writes SHA flag on success" {
  # Template already provides a git repo with initial commit.
  run _handle_test_gate_result "$TEST_PROJECT_DIR" "0" "all tests passed"
  [ "$status" -eq "$TESTGATE_PASS" ]

  # SHA flag should be written.
  [ -f "$TEST_PROJECT_DIR/.autopilot/test_verified_sha" ]
}

@test "_handle_test_gate_result returns FAIL on non-zero exit" {
  run _handle_test_gate_result "$TEST_PROJECT_DIR" "1" "test failed output"
  [ "$status" -eq "$TESTGATE_FAIL" ]
}

@test "_handle_test_gate_result writes output to log file" {
  _handle_test_gate_result "$TEST_PROJECT_DIR" "0" "test output here" || true

  local output_log="$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"
  [ -f "$output_log" ]
  local content
  content="$(cat "$output_log")"
  [[ "$content" == *"test output here"* ]]
}

@test "_handle_test_gate_result logs failure details" {
  _handle_test_gate_result "$TEST_PROJECT_DIR" "1" "FAIL: test_foo" "42" || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Test gate FAILED"* ]]
  [[ "$log_content" == *"raw_exit=42"* ]]
}

# --- has_test_gate_result ---

@test "has_test_gate_result returns 1 when no result file" {
  run has_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "has_test_gate_result returns 0 when result file exists" {
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  run has_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- clear_test_gate_result ---

@test "clear_test_gate_result removes result file" {
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  clear_test_gate_result "$TEST_PROJECT_DIR"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/test_gate_result" ]
}

@test "clear_test_gate_result is idempotent when no file" {
  run clear_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

# --- read_test_gate_result edge cases ---

@test "read_test_gate_result returns ERROR for missing file" {
  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "read_test_gate_result returns ERROR for empty file" {
  echo "" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "read_test_gate_result returns ERROR for non-numeric content" {
  echo "not-a-number" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "read_test_gate_result returns stored PASS code" {
  echo "0" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_PASS" ]
}

@test "read_test_gate_result returns stored FAIL code" {
  echo "1" > "$TEST_PROJECT_DIR/.autopilot/test_gate_result"

  run read_test_gate_result "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_FAIL" ]
}

# --- _has_bats ---

@test "_has_bats detects bats files in tests/ directory" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_foo.bats"

  run _has_bats "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_bats returns 1 when no tests directory" {
  run _has_bats "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "_has_bats returns 1 when tests dir has no bats files" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_foo.py"

  run _has_bats "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- _has_pytest ---

@test "_has_pytest detects conftest.py" {
  touch "$TEST_PROJECT_DIR/conftest.py"

  run _has_pytest "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_pytest detects tests/conftest.py" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/conftest.py"

  run _has_pytest "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_pytest detects pyproject.toml with pytest" {
  echo '[tool.pytest]' > "$TEST_PROJECT_DIR/pyproject.toml"

  run _has_pytest "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_pytest returns 1 when no Python indicators" {
  run _has_pytest "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- _has_npm_test ---

@test "_has_npm_test returns 0 when package.json has test script" {
  echo '{"scripts":{"test":"jest"}}' > "$TEST_PROJECT_DIR/package.json"

  run _has_npm_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_npm_test returns 1 when no package.json" {
  run _has_npm_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "_has_npm_test returns 1 when package.json has no test script" {
  echo '{"scripts":{"build":"tsc"}}' > "$TEST_PROJECT_DIR/package.json"

  run _has_npm_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- _has_make_test ---

@test "_has_make_test returns 0 when Makefile has test target" {
  printf 'test:\n\techo ok\n' > "$TEST_PROJECT_DIR/Makefile"

  run _has_make_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_has_make_test returns 1 when no Makefile" {
  run _has_make_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "_has_make_test returns 1 when Makefile has no test target" {
  printf 'build:\n\techo ok\n' > "$TEST_PROJECT_DIR/Makefile"

  run _has_make_test "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}
