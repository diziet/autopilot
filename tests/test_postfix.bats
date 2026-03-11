#!/usr/bin/env bats
# Tests for lib/postfix.sh — Post-fix verification, push verification,
# fix-tests agent spawning, test gate integration, and graceful degradation.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/postfix.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit
  TEST_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks_dir"
  mkdir -p "$TEST_HOOKS_DIR"
  TEST_CAPTURE_DIR="$BATS_TEST_TMPDIR/capture_dir"
  mkdir -p "$TEST_CAPTURE_DIR"

  # Re-load config per test (depends on TEST_PROJECT_DIR from template init).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _POSTFIX_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

# --- Exit Code Constants ---

@test "POSTFIX_PASS is 0" {
  [ "$POSTFIX_PASS" -eq 0 ]
}

@test "POSTFIX_FAIL is 1" {
  [ "$POSTFIX_FAIL" -eq 1 ]
}

@test "POSTFIX_ERROR is 2" {
  [ "$POSTFIX_ERROR" -eq 2 ]
}

@test "exit code constants are exported" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/postfix.sh" && echo "$POSTFIX_PASS:$POSTFIX_FAIL:$POSTFIX_ERROR"'
  [ "$status" -eq 0 ]
  [ "$output" = "0:1:2" ]
}

# --- fetch_remote_sha ---

@test "fetch_remote_sha returns SHA from gh api" {
  # Mock gh to return a known SHA.
  gh() {
    echo 'abc123def456'
  }
  export -f gh

  # Mock timeout to pass through.
  timeout() { shift; "$@"; }
  export -f timeout

  local result
  result="$(fetch_remote_sha "$TEST_PROJECT_DIR" "main")"
  [ "$result" = "abc123def456" ]
}

@test "fetch_remote_sha returns empty on gh api failure" {
  # Mock gh to fail.
  gh() { return 1; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  local result
  result="$(fetch_remote_sha "$TEST_PROJECT_DIR" "main")"
  [ -z "$result" ]
}

@test "fetch_remote_sha returns empty when repo slug fails" {
  get_repo_slug() { return 1; }
  export -f get_repo_slug

  local result
  result="$(fetch_remote_sha "$TEST_PROJECT_DIR" "main")"
  [ -z "$result" ]
}

@test "fetch_remote_sha uses AUTOPILOT_TIMEOUT_GH" {
  AUTOPILOT_TIMEOUT_GH=5

  # Use file-based capture since timeout runs in a subshell via $().
  local capture_file="${TEST_CAPTURE_DIR}/timeout_val"
  timeout() {
    echo "$1" > "$capture_file"
    shift
    "$@"
  }
  export -f timeout
  export capture_file

  gh() { echo "sha123"; }
  export -f gh

  fetch_remote_sha "$TEST_PROJECT_DIR" "main" >/dev/null
  [ "$(cat "$capture_file")" = "5" ]
}

# --- verify_fixer_push ---

@test "verify_fixer_push detects SHA change" {
  # Mock fetch_remote_sha to return different SHA.
  fetch_remote_sha() { echo "new_sha_456"; }

  run verify_fixer_push "$TEST_PROJECT_DIR" "autopilot/task-1" "old_sha_123"
  [ "$status" -eq 0 ]
}

@test "verify_fixer_push detects no push when SHA unchanged" {
  fetch_remote_sha() { echo "same_sha_123"; }

  run verify_fixer_push "$TEST_PROJECT_DIR" "autopilot/task-1" "same_sha_123"
  [ "$status" -eq 1 ]
}

@test "verify_fixer_push passes when no before-SHA available" {
  run verify_fixer_push "$TEST_PROJECT_DIR" "autopilot/task-1" ""
  [ "$status" -eq 0 ]
}

@test "verify_fixer_push degrades gracefully when fetch fails" {
  fetch_remote_sha() { echo ""; }

  run verify_fixer_push "$TEST_PROJECT_DIR" "autopilot/task-1" "old_sha"
  [ "$status" -eq 0 ]
}

# --- build_fix_tests_prompt ---

@test "build_fix_tests_prompt includes task number" {
  local result
  result="$(build_fix_tests_prompt 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "Task 5"
}

@test "build_fix_tests_prompt includes PR number" {
  local result
  result="$(build_fix_tests_prompt 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "PR #42"
}

@test "build_fix_tests_prompt includes branch name" {
  local result
  result="$(build_fix_tests_prompt 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_fix_tests_prompt includes test output" {
  local result
  result="$(build_fix_tests_prompt 5 42 "FAIL test_foo expected 1 got 2" "autopilot/task-5")"
  echo "$result" | grep -qF "FAIL test_foo"
}

@test "build_fix_tests_prompt trims output to AUTOPILOT_MAX_TEST_OUTPUT lines" {
  AUTOPILOT_MAX_TEST_OUTPUT=3

  # Create test output longer than 3 lines.
  local long_output
  long_output="$(printf 'line %d\n' {1..10})"

  local result
  result="$(build_fix_tests_prompt 1 1 "$long_output" "branch")"

  # Should contain last 3 lines.
  echo "$result" | grep -qF "line 8"
  echo "$result" | grep -qF "line 9"
  echo "$result" | grep -qF "line 10"

  # Should NOT contain early lines (line 2 avoids false match with line 10).
  ! echo "$result" | grep -qF "line 2"
}

@test "build_fix_tests_prompt includes fix instructions" {
  local result
  result="$(build_fix_tests_prompt 1 1 "output" "branch")"
  echo "$result" | grep -qF "fix:"
  echo "$result" | grep -qF "Push your commits"
}

# --- run_fix_tests ---

@test "run_fix_tests reads fix-tests.md prompt" {
  # Verify the prompt file exists.
  [ -f "$BATS_TEST_DIRNAME/../prompts/fix-tests.md" ]

  local prompt_content
  prompt_content="$(_read_prompt_file "${_POSTFIX_PROMPTS_DIR}/fix-tests.md")"
  echo "$prompt_content" | grep -qF "Test Fixer Agent"
}

@test "run_fix_tests spawns claude with correct timeout" {
  AUTOPILOT_TIMEOUT_FIX_TESTS=120

  # File-based capture since run_claude is called in $() subshell.
  local capture_file="${TEST_CAPTURE_DIR}/fix_timeout"
  run_claude() {
    echo "$1" > "$capture_file"
    local tmpf
    tmpf="$(mktemp)"
    echo '{"result":"fixed"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }

  install_hooks() { return 0; }
  remove_hooks() { return 0; }

  run_fix_tests "$TEST_PROJECT_DIR" 1 42 "test output" >/dev/null
  [ "$(cat "$capture_file")" = "120" ]
}

@test "run_fix_tests installs and removes hooks" {
  local install_flag="${TEST_CAPTURE_DIR}/hooks_installed"
  local remove_flag="${TEST_CAPTURE_DIR}/hooks_removed"

  install_hooks() { touch "$install_flag"; return 0; }
  remove_hooks() { touch "$remove_flag"; return 0; }

  run_claude() {
    local tmpf
    tmpf="$(mktemp)"
    echo '{"result":"ok"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }

  run_fix_tests "$TEST_PROJECT_DIR" 1 42 "test output" >/dev/null
  [ -f "$install_flag" ]
  [ -f "$remove_flag" ]
}

@test "run_fix_tests continues when hook install fails" {
  install_hooks() { return 1; }
  remove_hooks() { return 0; }

  run_claude() {
    local tmpf
    tmpf="$(mktemp)"
    echo '{"result":"ok"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }

  run run_fix_tests "$TEST_PROJECT_DIR" 1 42 "test output"
  [ "$status" -eq 0 ]
}

@test "run_fix_tests returns claude exit code on failure" {
  install_hooks() { return 0; }
  remove_hooks() { return 0; }

  run_claude() {
    local tmpf
    tmpf="$(mktemp)"
    echo "$tmpf"
    return 124
  }

  run run_fix_tests "$TEST_PROJECT_DIR" 1 42 "test output"
  [ "$status" -eq 124 ]
}

@test "run_fix_tests fails when prompt file missing" {
  _POSTFIX_PROMPTS_DIR="$TEST_PROJECT_DIR/nonexistent"

  run run_fix_tests "$TEST_PROJECT_DIR" 1 42 "test output"
  [ "$status" -eq 1 ]
}

# Mock _run_agent_with_hooks to capture _AGENT_WORK_DIR to a file.
_mock_agent_capture_work_dir() {
  local capture_file="$1"
  _run_agent_with_hooks() {
    echo "${_AGENT_WORK_DIR:-UNSET}" > "$capture_file"
    local tmpf
    tmpf="$(mktemp)"
    echo '{"result":"ok"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }
}

@test "run_fix_tests sets _AGENT_WORK_DIR to worktree path" {
  AUTOPILOT_USE_WORKTREES=true
  local capture_file="${TEST_CAPTURE_DIR}/fix_tests_work_dir"
  _mock_agent_capture_work_dir "$capture_file"

  run_fix_tests "$TEST_PROJECT_DIR" 7 42 "test output" >/dev/null

  [ "$(cat "$capture_file")" = "${TEST_PROJECT_DIR}/.autopilot/worktrees/task-7" ]
}

@test "run_fix_tests installs hooks pointing at worktree path" {
  AUTOPILOT_USE_WORKTREES=true
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  # Create worktree dir with a Makefile so hooks detect lint/test.
  local wt_path="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-7"
  mkdir -p "$wt_path"
  cat > "$wt_path/Makefile" <<'MAKEFILE'
lint:
	echo "linting"
test:
	echo "testing"
MAKEFILE

  # Mock run_claude to succeed without spawning an agent.
  run_claude() {
    local tmpf; tmpf="$(mktemp)"
    echo '{"result":"ok"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }

  # Mock resolve_task_dir to return the worktree path.
  resolve_task_dir() { echo "$wt_path"; }

  run_fix_tests "$TEST_PROJECT_DIR" 7 42 "test output" >/dev/null

  # Hooks should have been cleaned up, but verify they referenced the worktree
  # by checking that install_hooks was called with the right path.
  # Re-install to inspect the settings content directly.
  install_hooks "$wt_path" "$TEST_HOOKS_DIR"

  local settings_file
  settings_file="$(resolve_settings_file "$TEST_HOOKS_DIR")"
  local hook_content
  hook_content="$(cat "$settings_file")"

  # Hook commands must reference the worktree, NOT the project root.
  [[ "$hook_content" == *"$wt_path"* ]]
  [[ "$hook_content" != *"cd '${TEST_PROJECT_DIR}'"* ]] || \
    [[ "$hook_content" == *"cd '${wt_path}'"* ]]

  remove_hooks "$wt_path" "$TEST_HOOKS_DIR"
}

@test "run_fix_tests uses project_dir when worktrees disabled" {
  AUTOPILOT_USE_WORKTREES=false
  local capture_file="${TEST_CAPTURE_DIR}/fix_tests_work_dir_direct"
  _mock_agent_capture_work_dir "$capture_file"

  run_fix_tests "$TEST_PROJECT_DIR" 7 42 "test output" >/dev/null

  [ "$(cat "$capture_file")" = "$TEST_PROJECT_DIR" ]
}

# --- _pull_latest ---

@test "_pull_latest handles missing remote branch gracefully" {
  # No remote branch exists.
  run _pull_latest "$TEST_PROJECT_DIR" "nonexistent-branch"
  [ "$status" -eq 0 ]
}

# --- _run_postfix_tests ---

@test "_run_postfix_tests clears SHA flag before running" {
  # Write a SHA flag.
  write_hook_sha_flag "$TEST_PROJECT_DIR" "old_sha"
  [ -f "$TEST_PROJECT_DIR/.autopilot/test_verified_sha" ]

  # Mock _resolve_test_cmd to verify flag was cleared before resolve.
  _resolve_test_cmd() {
    local flag_file="${1}/.autopilot/test_verified_sha"
    if [ -f "$flag_file" ]; then
      return 99
    fi
    echo "true"
    return 0
  }

  # Mock _run_test_cmd to succeed.
  _run_test_cmd() { return 0; }

  run _run_postfix_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "_run_postfix_tests captures and echoes test output" {
  # Mock test resolution and execution to produce output.
  _resolve_test_cmd() { echo "echo test-output-here"; }
  _run_test_cmd() {
    echo "FAIL test_example"
    echo "expected 1 got 2"
    return 1
  }

  local output
  output="$(_run_postfix_tests "$TEST_PROJECT_DIR")" || true
  echo "$output" | grep -qF "FAIL test_example"
  echo "$output" | grep -qF "expected 1 got 2"
}

@test "_run_postfix_tests returns TESTGATE_SKIP when no test command" {
  _resolve_test_cmd() { return "$TESTGATE_SKIP"; }

  run _run_postfix_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_SKIP" ]
}

@test "_run_postfix_tests writes SHA flag on pass" {
  _add_git_to_test_dir
  _resolve_test_cmd() { echo "true"; }
  _run_test_cmd() { return 0; }

  _run_postfix_tests "$TEST_PROJECT_DIR" >/dev/null
  [ -f "$TEST_PROJECT_DIR/.autopilot/test_verified_sha" ]
}

@test "_run_postfix_tests uses two-phase runner for bats" {
  local phase_flag="${TEST_CAPTURE_DIR}/twophase_called"

  _resolve_test_cmd() { echo "bats tests/"; }

  # Fail explicitly if _run_test_cmd is called — bats should use two-phase.
  _run_test_cmd() { echo "ERROR: _run_test_cmd should not be called for bats"; return 99; }

  # Mock timeout to intercept the bash -c call and run our mock instead.
  timeout() {
    touch "$phase_flag"
    echo "two-phase-output"
    return 0
  }

  # Ensure AUTOPILOT_TEST_CMD is unset so bats detection triggers.
  unset AUTOPILOT_TEST_CMD

  local output
  output="$(_run_postfix_tests "$TEST_PROJECT_DIR")" || true
  [ -f "$phase_flag" ]
  echo "$output" | grep -qF "two-phase-output"
}

@test "_run_postfix_tests maps two-phase failure to TESTGATE_FAIL" {
  _resolve_test_cmd() { echo "bats tests/"; }
  _run_test_cmd() { return 99; }

  timeout() {
    echo "not ok 1 - test_something"
    return 1
  }

  unset AUTOPILOT_TEST_CMD

  run _run_postfix_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_FAIL" ]
}

@test "_run_postfix_tests logs timeout warning for bats" {
  _resolve_test_cmd() { echo "bats tests/"; }
  _run_test_cmd() { return 99; }

  # Simulate timeout killing the process (exit 124).
  timeout() {
    echo "partial output before timeout"
    return 124
  }

  unset AUTOPILOT_TEST_CMD

  run _run_postfix_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq "$TESTGATE_FAIL" ]
  # Log file should mention timeout.
  grep -qF "timed out" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "_run_postfix_tests returns TESTGATE_ERROR when twophase.sh missing" {
  _resolve_test_cmd() { echo "bats tests/"; }
  unset AUTOPILOT_TEST_CMD

  # Override twophase path to a non-existent file (avoids race with parallel tests).
  _POSTFIX_TWOPHASE_PATH="/nonexistent/twophase.sh"

  run _run_postfix_tests "$TEST_PROJECT_DIR"

  [ "$status" -eq "$TESTGATE_ERROR" ]
}

@test "_run_postfix_tests uses _run_test_cmd for non-bats" {
  local cmd_flag="${TEST_CAPTURE_DIR}/run_test_cmd_called"

  _resolve_test_cmd() { echo "pytest -p no:cov"; }
  _run_test_cmd() {
    touch "$cmd_flag"
    echo "pytest-output"
    return 0
  }

  unset AUTOPILOT_TEST_CMD

  local output
  output="$(_run_postfix_tests "$TEST_PROJECT_DIR")"
  [ -f "$cmd_flag" ]
  echo "$output" | grep -qF "pytest-output"
}

@test "_run_postfix_tests uses _run_test_cmd when AUTOPILOT_TEST_CMD set even for bats" {
  local cmd_flag="${TEST_CAPTURE_DIR}/run_test_cmd_called"

  AUTOPILOT_TEST_CMD="bats tests/"
  _resolve_test_cmd() { echo "bats tests/"; }
  _run_test_cmd() {
    touch "$cmd_flag"
    echo "sequential-bats-output"
    return 0
  }

  local output
  output="$(_run_postfix_tests "$TEST_PROJECT_DIR")"
  [ -f "$cmd_flag" ]
  echo "$output" | grep -qF "sequential-bats-output"
}

# --- _run_postfix_tests stale log clearing ---

@test "_run_postfix_tests clears stale output log before running" {
  # Write stale output from a previous run.
  echo "stale output from previous run" > "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"
  echo "99" > "$TEST_PROJECT_DIR/.autopilot/test_gate_duration"

  AUTOPILOT_TEST_CMD="echo fresh"
  _resolve_test_cmd() { echo "echo fresh"; }
  _run_test_cmd() { echo "fresh output"; return 0; }

  _run_postfix_tests "$TEST_PROJECT_DIR" >/dev/null || true

  # Stale output log should have been removed before the run.
  # The function doesn't write output_log itself (only echoes), so the
  # stale file should be gone.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log" ] || {
    local content
    content="$(cat "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log")"
    [[ "$content" != *"stale"* ]]
  }
}

@test "_run_postfix_tests writes duration file" {
  AUTOPILOT_TEST_CMD="true"
  _resolve_test_cmd() { echo "true"; }
  _run_test_cmd() { echo "ok 1 test_a"; return 0; }

  _run_postfix_tests "$TEST_PROJECT_DIR" >/dev/null || true

  local duration_file="$TEST_PROJECT_DIR/.autopilot/test_gate_duration"
  [ -f "$duration_file" ]
  local duration
  duration="$(cat "$duration_file")"
  [[ "$duration" =~ ^[0-9]+$ ]]
}

# --- _run_postfix_tests timer and summary logging ---

@test "_run_postfix_tests logs TIMER line" {
  AUTOPILOT_TEST_CMD="true"
  _resolve_test_cmd() { echo "true"; }
  _run_test_cmd() { echo "ok 1 test_a"; return 0; }

  _run_postfix_tests "$TEST_PROJECT_DIR" >/dev/null || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TIMER: post-fix tests ("*"s)"* ]]
}

@test "_run_postfix_tests logs TEST_GATE summary with TAP output" {
  AUTOPILOT_TEST_CMD="true"
  _resolve_test_cmd() { echo "true"; }
  _run_test_cmd() { printf 'ok 1 test_a\nok 2 test_b\nnot ok 3 test_c\n'; return 1; }

  _run_postfix_tests "$TEST_PROJECT_DIR" >/dev/null 2>&1 || true
  local log
  log="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log" == *"TEST_GATE: Tests: 3 total, 2 passed, 1 failed"* ]]
}

# --- run_postfix_verification ---

@test "run_postfix_verification returns PASS when tests pass" {
  # Mock all external calls.
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_PASS"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "run_postfix_verification returns PASS when tests skip" {
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_SKIP"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "run_postfix_verification returns PASS when already verified" {
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_ALREADY_VERIFIED"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "run_postfix_verification returns POSTFIX_ERROR on TESTGATE_ERROR" {
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_ERROR"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_ERROR" ]
}

@test "run_postfix_verification spawns fix-tests on failure then passes" {
  local fix_flag="${TEST_CAPTURE_DIR}/fix_tests_called"
  local call_counter="${TEST_CAPTURE_DIR}/test_call_count"
  echo "0" > "$call_counter"

  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }

  # Use file-based counter since _run_postfix_tests runs in $() subshell.
  _run_postfix_tests() {
    local count
    count="$(cat "$call_counter")"
    count=$((count + 1))
    echo "$count" > "$call_counter"
    if [ "$count" -eq 1 ]; then
      echo "FAIL test_something"
      return "$TESTGATE_FAIL"
    fi
    return "$TESTGATE_PASS"
  }

  run_fix_tests() {
    touch "$fix_flag"
    return 0
  }

  # Initialize test fix retry counter.
  init_pipeline "$TEST_PROJECT_DIR"

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_PASS" ]
  [ -f "$fix_flag" ]
}

@test "run_postfix_verification fails when retries exhausted" {
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() {
    echo "FAIL test_something"
    return "$TESTGATE_FAIL"
  }

  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  # Initialize state and set retries to max.
  init_pipeline "$TEST_PROJECT_DIR"
  write_state_num "$TEST_PROJECT_DIR" "test_fix_retries" 3

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_FAIL" ]
}

@test "run_postfix_verification increments test_fix_retries" {
  local call_counter="${TEST_CAPTURE_DIR}/test_call_count"
  echo "0" > "$call_counter"

  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }

  _run_postfix_tests() {
    local count
    count="$(cat "$call_counter")"
    count=$((count + 1))
    echo "$count" > "$call_counter"
    if [ "$count" -eq 1 ]; then
      echo "FAIL"
      return "$TESTGATE_FAIL"
    fi
    return "$TESTGATE_PASS"
  }

  run_fix_tests() { return 0; }

  init_pipeline "$TEST_PROJECT_DIR"

  run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"

  local retries
  retries="$(get_test_fix_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 1 ]
}

@test "run_postfix_verification proceeds when push verification fails" {
  verify_fixer_push() { return 1; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_PASS"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha_before"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "run_postfix_verification works with empty sha_before" {
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_PASS"; }

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 ""
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "run_postfix_verification returns FAIL when fix-tests and retest fail" {
  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }
  _run_postfix_tests() {
    echo "FAIL"
    return "$TESTGATE_FAIL"
  }
  run_fix_tests() { return 1; }

  init_pipeline "$TEST_PROJECT_DIR"
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha"
  [ "$status" -eq "$POSTFIX_FAIL" ]
}

@test "run_postfix_verification captures test output for fix-tests agent" {
  local prompt_file="${TEST_CAPTURE_DIR}/fix_prompt"
  local call_counter="${TEST_CAPTURE_DIR}/test_call_count"
  echo "0" > "$call_counter"

  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }

  _run_postfix_tests() {
    local count
    count="$(cat "$call_counter")"
    count=$((count + 1))
    echo "$count" > "$call_counter"
    if [ "$count" -eq 1 ]; then
      echo "FAIL test_auth_returns_401"
      echo "expected 401 got 200"
      return "$TESTGATE_FAIL"
    fi
    return "$TESTGATE_PASS"
  }

  # Capture what run_fix_tests receives as test_output.
  run_fix_tests() {
    echo "$4" > "$prompt_file"
    return 0
  }

  init_pipeline "$TEST_PROJECT_DIR"

  run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha" >/dev/null
  grep -qF "FAIL test_auth_returns_401" "$prompt_file"
  grep -qF "expected 401 got 200" "$prompt_file"
}

@test "run_postfix_verification uses build_branch_name for branch" {
  AUTOPILOT_BRANCH_PREFIX="custom-prefix"

  local branch_file="${TEST_CAPTURE_DIR}/branch_name"
  verify_fixer_push() { return 0; }
  _pull_latest() {
    echo "$2" > "$branch_file"
    return 0
  }
  _run_postfix_tests() { return "$TESTGATE_PASS"; }

  run_postfix_verification "$TEST_PROJECT_DIR" 7 42 "sha" >/dev/null
  grep -qF "custom-prefix/task-7" "$branch_file"
}

@test "run_postfix_verification does not leak run_fix_tests stdout" {
  local call_counter="${TEST_CAPTURE_DIR}/test_call_count"
  echo "0" > "$call_counter"

  verify_fixer_push() { return 0; }
  _pull_latest() { return 0; }

  _run_postfix_tests() {
    local count
    count="$(cat "$call_counter")"
    count=$((count + 1))
    echo "$count" > "$call_counter"
    if [ "$count" -eq 1 ]; then
      echo "FAIL"
      return "$TESTGATE_FAIL"
    fi
    return "$TESTGATE_PASS"
  }

  run_fix_tests() {
    echo "/tmp/autopilot-claude.leaked"
    return 0
  }

  init_pipeline "$TEST_PROJECT_DIR"

  local output
  output="$(run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "sha")"
  # Output should NOT contain the leaked temp file path.
  ! echo "$output" | grep -qF "autopilot-claude.leaked"
}

# --- _run_agent_with_hooks ---

@test "_run_agent_with_hooks installs and removes hooks" {
  local install_flag="${TEST_CAPTURE_DIR}/hooks_installed"
  local remove_flag="${TEST_CAPTURE_DIR}/hooks_removed"

  install_hooks() { touch "$install_flag"; return 0; }
  remove_hooks() { touch "$remove_flag"; return 0; }

  run_claude() {
    local tmpf
    tmpf="$(mktemp)"
    echo '{"result":"ok"}' > "$tmpf"
    echo "$tmpf"
    return 0
  }

  _run_agent_with_hooks "$TEST_PROJECT_DIR" "" "TestAgent" 1 60 "prompt" >/dev/null
  [ -f "$install_flag" ]
  [ -f "$remove_flag" ]
}

@test "_run_agent_with_hooks passes extra args to run_claude" {
  local args_file="${TEST_CAPTURE_DIR}/extra_args"
  install_hooks() { return 0; }
  remove_hooks() { return 0; }

  run_claude() {
    # Skip first 3 args (timeout, prompt, config_dir).
    shift 3
    echo "$*" > "$args_file"
    local tmpf
    tmpf="$(mktemp)"
    echo "$tmpf"
    return 0
  }

  _run_agent_with_hooks "$TEST_PROJECT_DIR" "" "TestAgent" 1 60 "prompt" \
    "--system-prompt" "sysprompt" >/dev/null
  grep -qF -- "--system-prompt sysprompt" "$args_file"
}

@test "_run_agent_with_hooks returns claude exit code" {
  install_hooks() { return 0; }
  remove_hooks() { return 0; }

  run_claude() {
    local tmpf
    tmpf="$(mktemp)"
    echo "$tmpf"
    return 124
  }

  run _run_agent_with_hooks "$TEST_PROJECT_DIR" "" "TestAgent" 1 60 "prompt"
  [ "$status" -eq 124 ]
}

# --- Integration-style tests ---

@test "full postfix flow: tests pass immediately" {
  # Set up mocks for a clean pass scenario.
  fetch_remote_sha() { echo "new_sha"; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_PASS"; }

  init_pipeline "$TEST_PROJECT_DIR"

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "old_sha"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "full postfix flow: tests fail then pass after fix" {
  local call_counter="${TEST_CAPTURE_DIR}/test_call_count"
  echo "0" > "$call_counter"

  fetch_remote_sha() { echo "new_sha"; }
  _pull_latest() { return 0; }

  _run_postfix_tests() {
    local count
    count="$(cat "$call_counter")"
    count=$((count + 1))
    echo "$count" > "$call_counter"
    if [ "$count" -le 1 ]; then
      echo "FAIL test_something"
      return "$TESTGATE_FAIL"
    fi
    return "$TESTGATE_PASS"
  }

  run_fix_tests() { return 0; }

  init_pipeline "$TEST_PROJECT_DIR"

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "old_sha"
  [ "$status" -eq "$POSTFIX_PASS" ]
}

@test "full postfix flow: test gate error returns POSTFIX_ERROR" {
  fetch_remote_sha() { echo "new_sha"; }
  _pull_latest() { return 0; }
  _run_postfix_tests() { return "$TESTGATE_ERROR"; }

  init_pipeline "$TEST_PROJECT_DIR"

  run run_postfix_verification "$TEST_PROJECT_DIR" 1 42 "old_sha"
  [ "$status" -eq "$POSTFIX_ERROR" ]
}
