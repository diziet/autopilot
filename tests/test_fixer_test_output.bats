#!/usr/bin/env bats
# Tests for Task 98: Include all failing test output in fixer prompt.
# Verifies save/read/truncation of per-task test output, inclusion in
# fixer prompt, and inclusion in fix-tests (test-fixer) prompt.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/testgate.sh"
source "$BATS_TEST_DIRNAME/../lib/fixer.sh"
source "$BATS_TEST_DIRNAME/../lib/postfix.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit

  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dirs.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
  _POSTFIX_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

# --- save_task_test_output ---

@test "save_task_test_output copies test_gate_output.log to per-task file" {
  echo "FAIL: test_something expected 1 got 2" \
    > "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"

  save_task_test_output "$TEST_PROJECT_DIR" "42"

  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-42.txt"
  [ -f "$dest" ]
  grep -q "FAIL: test_something" "$dest"
}

@test "save_task_test_output reads from source_dir when provided (worktree mode)" {
  # Simulate worktree: test_gate_output.log is in a different directory.
  local worktree_dir="$TEST_PROJECT_DIR/.autopilot/worktrees/task-42"
  mkdir -p "$worktree_dir/.autopilot"
  echo "FAIL: worktree_test expected true got false" \
    > "$worktree_dir/.autopilot/test_gate_output.log"

  # No output log in project_dir — only in worktree_dir.
  rm -f "$TEST_PROJECT_DIR/.autopilot/test_gate_output.log"

  save_task_test_output "$TEST_PROJECT_DIR" "42" "$worktree_dir"

  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-42.txt"
  [ -f "$dest" ]
  grep -q "FAIL: worktree_test" "$dest"
}

@test "save_task_test_output returns 1 when no output log exists" {
  run save_task_test_output "$TEST_PROJECT_DIR" "99"
  [ "$status" -eq 1 ]
}

# --- save_task_test_output_raw ---

@test "save_task_test_output_raw writes raw output to per-task file" {
  save_task_test_output_raw "$TEST_PROJECT_DIR" "7" "error: assertion failed"

  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-7.txt"
  [ -f "$dest" ]
  grep -q "assertion failed" "$dest"
}

# --- read_task_test_output ---

@test "read_task_test_output returns saved output" {
  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-5.txt"
  echo "FAIL: broken_test" > "$dest"

  local result
  result="$(read_task_test_output "$TEST_PROJECT_DIR" "5")"
  echo "$result" | grep -q "FAIL: broken_test"
}

@test "read_task_test_output returns empty when no file exists" {
  local result
  result="$(read_task_test_output "$TEST_PROJECT_DIR" "999")"
  [ -z "$result" ]
}

@test "read_task_test_output truncates output exceeding AUTOPILOT_MAX_TEST_OUTPUT" {
  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-10.txt"
  # Generate 20 lines of output.
  local i
  for i in $(seq 1 20); do
    echo "line $i"
  done > "$dest"

  # Set limit to 5 lines.
  AUTOPILOT_MAX_TEST_OUTPUT=5

  local result
  result="$(read_task_test_output "$TEST_PROJECT_DIR" "10")"

  # Should contain only last 5 lines (16-20).
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 5 ]
  echo "$result" | grep -q "line 20"
  echo "$result" | grep -q "line 16"
  # Should NOT contain line 15.
  ! echo "$result" | grep -q "line 15"
}

@test "read_task_test_output returns full output when under limit" {
  local dest="$TEST_PROJECT_DIR/.autopilot/logs/test-output-task-11.txt"
  printf "line 1\nline 2\nline 3\n" > "$dest"

  AUTOPILOT_MAX_TEST_OUTPUT=500

  local result
  result="$(read_task_test_output "$TEST_PROJECT_DIR" "11")"
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 3 ]
}

# --- build_fixer_prompt includes test output ---

@test "build_fixer_prompt includes test output section when provided" {
  local ctx
  ctx="$(build_fixer_context_sections "" "" "FAIL: test_broken")"
  local result
  result="$(build_fixer_prompt "123" "autopilot/task-1" \
    "reviewer feedback" "owner/repo" "$ctx")"

  echo "$result" | grep -q "Failing Tests"
  echo "$result" | grep -q "FAIL: test_broken"
  echo "$result" | grep -q "Fix all of them"
}

@test "build_fixer_prompt omits test output section when empty" {
  local ctx
  ctx="$(build_fixer_context_sections "" "" "")"
  local result
  result="$(build_fixer_prompt "123" "autopilot/task-1" \
    "reviewer feedback" "owner/repo" "$ctx")"

  ! echo "$result" | grep -q "Failing Tests"
}

@test "build_fixer_prompt includes both diagnosis hints and test output" {
  local ctx
  ctx="$(build_fixer_context_sections "hint: check imports" "" "FAIL: test_imports")"
  local result
  result="$(build_fixer_prompt "123" "autopilot/task-1" \
    "reviewer feedback" "owner/repo" "$ctx")"

  echo "$result" | grep -q "Diagnosis from Previous Attempt"
  echo "$result" | grep -q "hint: check imports"
  echo "$result" | grep -q "Failing Tests"
  echo "$result" | grep -q "FAIL: test_imports"
}

# --- build_fix_tests_prompt truncation ---

@test "build_fix_tests_prompt truncates output exceeding AUTOPILOT_MAX_TEST_OUTPUT" {
  # Generate 20 lines of test output.
  local test_output=""
  local i
  for i in $(seq 1 20); do
    test_output="${test_output}line ${i}
"
  done

  AUTOPILOT_MAX_TEST_OUTPUT=5

  local result
  result="$(build_fix_tests_prompt "1" "100" "$test_output" "autopilot/task-1")"

  # Should mention truncation.
  echo "$result" | grep -q "truncated"
  # Should contain line 20 (last line).
  echo "$result" | grep -q "line 20"
  # Should NOT contain line 14 (outside last 5 lines + empty).
  ! echo "$result" | grep -q "line 14"
}

@test "build_fix_tests_prompt includes full output when under limit" {
  AUTOPILOT_MAX_TEST_OUTPUT=500

  local result
  result="$(build_fix_tests_prompt "1" "100" "single failure" "autopilot/task-1")"

  echo "$result" | grep -q "single failure"
  ! echo "$result" | grep -q "truncated"
}

@test "build_fix_tests_prompt includes fix-all instruction" {
  local result
  result="$(build_fix_tests_prompt "1" "100" "FAIL" "autopilot/task-1")"

  echo "$result" | grep -q "Fix all of them"
}
