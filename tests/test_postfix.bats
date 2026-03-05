#!/usr/bin/env bats
# Tests for lib/postfix.sh — Post-fix verification, push verification,
# fix-tests agent spawning, test gate integration, and graceful degradation.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_HOOKS_DIR="$(mktemp -d)"
  TEST_CAPTURE_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source postfix.sh (which sources config, state, claude, testgate, hooks, git-ops).
  source "$BATS_TEST_DIRNAME/../lib/postfix.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _POSTFIX_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Set up a fake git repo for get_repo_slug.
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git"

  # Create an initial commit so HEAD exists.
  touch "$TEST_PROJECT_DIR/.gitkeep"
  git -C "$TEST_PROJECT_DIR" add .gitkeep
  git -C "$TEST_PROJECT_DIR" commit -q -m "initial"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
  rm -rf "$TEST_CAPTURE_DIR"
}

# --- Exit Code Constants ---

@test "POSTFIX_PASS is 0" {
  [ "$POSTFIX_PASS" -eq 0 ]
}

@test "POSTFIX_FAIL is 1" {
  [ "$POSTFIX_FAIL" -eq 1 ]
}

@test "POSTFIX_NO_PUSH is 2" {
  [ "$POSTFIX_NO_PUSH" -eq 2 ]
}

@test "POSTFIX_ERROR is 3" {
  [ "$POSTFIX_ERROR" -eq 3 ]
}

@test "exit code constants are exported" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/postfix.sh" && echo "$POSTFIX_PASS:$POSTFIX_FAIL:$POSTFIX_NO_PUSH:$POSTFIX_ERROR"'
  [ "$status" -eq 0 ]
  [ "$output" = "0:1:2:3" ]
}

# --- fetch_remote_sha ---

@test "fetch_remote_sha returns SHA from gh api" {
  # Mock gh to return a known SHA.
  gh() {
    echo '{"object":{"sha":"abc123def456"}}' | jq -r '.object.sha'
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
  # Remove git remote so get_repo_slug fails.
  git -C "$TEST_PROJECT_DIR" remote remove origin

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
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "Task 5"
}

@test "build_fix_tests_prompt includes PR number" {
  local result
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "PR #42"
}

@test "build_fix_tests_prompt includes branch name" {
  local result
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 5 42 "FAIL test_foo" "autopilot/task-5")"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_fix_tests_prompt includes test output" {
  local result
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 5 42 "FAIL test_foo expected 1 got 2" "autopilot/task-5")"
  echo "$result" | grep -qF "FAIL test_foo"
}

@test "build_fix_tests_prompt trims output to AUTOPILOT_TEST_OUTPUT_TAIL lines" {
  AUTOPILOT_TEST_OUTPUT_TAIL=3

  # Create test output longer than 3 lines.
  local long_output
  long_output="$(printf 'line %d\n' {1..10})"

  local result
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 1 1 "$long_output" "branch")"

  # Should contain last 3 lines.
  echo "$result" | grep -qF "line 8"
  echo "$result" | grep -qF "line 9"
  echo "$result" | grep -qF "line 10"
}

@test "build_fix_tests_prompt includes fix instructions" {
  local result
  result="$(build_fix_tests_prompt "$TEST_PROJECT_DIR" 1 1 "output" "branch")"
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

  # Mock run_test_gate to verify flag was cleared.
  run_test_gate() {
    local flag_file="${1}/.autopilot/test_verified_sha"
    if [ -f "$flag_file" ]; then
      return 99
    fi
    return 0
  }

  run _run_postfix_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
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

# --- Integration-style tests ---

@test "full postfix flow: tests pass immediately" {
  # Set up mocks for a clean pass scenario.
  fetch_remote_sha() { echo "new_sha"; }
  timeout() { shift; "$@"; }
  export -f timeout

  _pull_latest() { return 0; }

  # Mock run_test_gate to pass.
  run_test_gate() { return 0; }

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
