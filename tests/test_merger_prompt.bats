#!/usr/bin/env bats
# Tests for lib/merger-prompt.sh — the merge review prompt, and the PR diff
# and changed-file list fetched for it.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/merger-prompt.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  # Default gh and timeout mocks. Tests that need other behavior redefine them.
  gh() { return 0; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout
}

# --- build_merger_prompt ---

@test "build_merger_prompt includes PR number and branch" {
  local result
  result="$(build_merger_prompt 42 "autopilot/task-5" "owner/repo" "diff content")"
  echo "$result" | grep -qF "PR #42"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_merger_prompt includes repo slug" {
  local result
  result="$(build_merger_prompt 10 "branch" "myorg/myrepo" "diff")"
  echo "$result" | grep -qF "myorg/myrepo"
}

@test "build_merger_prompt includes diff content" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "+added line
-removed line")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "build_merger_prompt includes verdict instructions" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff")"
  echo "$result" | grep -qF "VERDICT: APPROVE"
  echo "$result" | grep -qF "VERDICT: REJECT"
}

@test "build_merger_prompt omits task section when no description" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "")"
  [[ "$result" != *"Task Description"* ]] || false
}

@test "build_merger_prompt includes task description when provided" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "Implement user auth")"
  echo "$result" | grep -qF "Task Description"
  echo "$result" | grep -qF "Implement user auth"
}

# --- build_merger_prompt with file list ---

@test "build_merger_prompt includes file list section when provided" {
  local file_list="lib/merger.sh | +10 -3
tests/test.bats | +5 -0"
  local result
  result="$(build_merger_prompt 42 "b" "o/r" "diff content" "" "$file_list")"
  echo "$result" | grep -qF "Changed Files"
  echo "$result" | grep -qF "lib/merger.sh"
  echo "$result" | grep -qF "tests/test.bats"
  echo "$result" | grep -qF "+10 -3"
}

@test "build_merger_prompt places file list before diff" {
  local file_list="src/app.sh | +3 -0"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "+added" "" "$file_list")"
  local file_list_pos diff_pos
  file_list_pos="$(echo "$result" | grep -n "Changed Files" | head -1 | cut -d: -f1)"
  diff_pos="$(echo "$result" | grep -n "Diff to Review" | head -1 | cut -d: -f1)"
  [ "$file_list_pos" -lt "$diff_pos" ]
}

@test "build_merger_prompt includes truncation note in file list section" {
  local file_list="file.sh | +1 -0"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "" "$file_list")"
  echo "$result" | grep -qF "The file list above is complete"
  echo "$result" | grep -qF "Do not reject for missing files"
}

@test "build_merger_prompt omits file list section when empty" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "" "")"
  [[ "$result" != *"Changed Files"* ]] || false
  [[ "$result" != *"file list above is complete"* ]] || false
}

@test "build_merger_prompt includes both task description and file list" {
  local file_list="main.sh | +1 -1"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "Add feature X" "$file_list")"
  echo "$result" | grep -qF "Task Description"
  echo "$result" | grep -qF "Add feature X"
  echo "$result" | grep -qF "Changed Files"
  echo "$result" | grep -qF "main.sh"
}

@test "build_merger_prompt handles PR with many files in file list" {
  local file_list=""
  local i
  for i in $(seq 1 20); do
    file_list="${file_list}src/module${i}.sh | +$((i * 2)) -0
"
  done
  local result
  result="$(build_merger_prompt 99 "b" "o/r" "truncated diff" "" "$file_list")"
  echo "$result" | grep -qF "module1.sh"
  echo "$result" | grep -qF "module20.sh"
}

# --- _fetch_merger_diff (mocked gh) ---

@test "_fetch_merger_diff returns diff content from gh" {
  gh() {
    echo "+added line"
    echo "-removed line"
    return 0
  }
  export -f gh

  local result
  result="$(_fetch_merger_diff "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "_fetch_merger_diff returns empty on gh failure" {
  gh() { return 1; }
  export -f gh

  local result
  result="$(_fetch_merger_diff "$TEST_PROJECT_DIR" 99 "testowner/testrepo" || true)"
  [ -z "$result" ]
}

@test "_fetch_merger_diff fails with empty repo slug" {
  run _fetch_merger_diff "$TEST_PROJECT_DIR" 42 ""
  [ "$status" -ne 0 ]
}

# --- _fetch_pr_file_list (mocked gh) ---

@test "_fetch_pr_file_list returns file stats from gh api" {
  gh() {
    echo "lib/merger.sh | +10 -3"
    echo "tests/test.bats | +5 -0"
    return 0
  }
  export -f gh

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "lib/merger.sh"
  echo "$result" | grep -qF "tests/test.bats"
  echo "$result" | grep -qF "+10 -3"
}

@test "_fetch_pr_file_list returns empty on gh failure" {
  gh() { return 1; }
  export -f gh

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 99 "testowner/testrepo")"
  [ -z "$result" ]
}

@test "_fetch_pr_file_list fails with empty repo slug" {
  run _fetch_pr_file_list "$TEST_PROJECT_DIR" 42 ""
  [ "$status" -ne 0 ]
}

@test "_fetch_pr_file_list handles many files" {
  gh() {
    local i
    for i in $(seq 1 25); do
      echo "src/file${i}.sh | +$((i * 2)) -0"
    done
    return 0
  }
  export -f gh

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 100 "testowner/testrepo")"
  echo "$result" | grep -qF "file1.sh"
  echo "$result" | grep -qF "file25.sh"
  # Verify we got 25 lines of output.
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 25 ]
}
