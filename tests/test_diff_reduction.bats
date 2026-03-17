#!/usr/bin/env bats
# Tests for lib/diff-reduction.sh — diff-reduction reviewer and oversized diff re-check.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/review_entry_setup

# Override setup to also source diff-reduction module.
setup() {
  _init_test_from_template_nogit

  GH_MOCK_DIR="$BATS_TEST_TMPDIR/gh_mocks"
  mkdir -p "$GH_MOCK_DIR"
  export GH_MOCK_DIR

  source "$BATS_TEST_DIRNAME/../lib/review-runner.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"

  _mock_gh
  _mock_claude
  _mock_timeout

  # Create tasks file for task description extraction.
  cat > "$TEST_PROJECT_DIR/tasks.md" <<'TASKS'
## Task 1

Build the widget with buttons.

## Task 2

Another task.
TASKS
  _CACHED_TASKS_FILE=""
  _CACHED_TASKS_FILE_DIR=""
  source "$BATS_TEST_DIRNAME/../lib/tasks.sh"
}

# --- _run_diff_reduction_review ---

@test "diff-reduction review: runs diff-reduction reviewer and transitions to reviewed" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  # Create a sampled diff file.
  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "sampled diff content" > "$diff_file"

  # Mock run_reviewers to return a result directory.
  export _DR_REVIEWERS_CALLED="$BATS_TEST_TMPDIR/dr_reviewers"
  run_reviewers() {
    echo "$AUTOPILOT_REVIEWERS" > "$_DR_REVIEWERS_CALLED"
    local rd
    rd="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"
    echo "$rd"
  }
  export -f run_reviewers

  post_review_comments() { return 0; }
  export -f post_review_comments

  _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "cron"

  # Verify it used the diff-reduction persona.
  [ "$(cat "$_DR_REVIEWERS_CALLED")" = "diff-reduction" ]

  # Verify state transitioned to reviewed.
  [ "$(_get_status)" = "reviewed" ]

  # Verify diff_reduction_active flag is set.
  local active
  active="$(read_state "$TEST_PROJECT_DIR" "diff_reduction_active")"
  [ "$active" = "true" ]
}

@test "diff-reduction review: increments retry counter in cron mode" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "content" > "$diff_file"

  run_reviewers() {
    local rd
    rd="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"
    echo "$rd"
  }
  export -f run_reviewers
  post_review_comments() { return 0; }
  export -f post_review_comments

  _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "cron"

  local retries
  retries="$(get_diff_reduction_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 1 ]
}

@test "diff-reduction review: does not modify state in standalone mode" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "content" > "$diff_file"

  run_reviewers() {
    local rd
    rd="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"
    echo "$rd"
  }
  export -f run_reviewers
  post_review_comments() { return 0; }
  export -f post_review_comments

  _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "standalone"

  # State should not change.
  [ "$(_get_status)" = "pr_open" ]

  # No retry counter increment.
  local retries
  retries="$(get_diff_reduction_retries "$TEST_PROJECT_DIR")"
  [ "$retries" -eq 0 ]
}

@test "diff-reduction review: restores AUTOPILOT_REVIEWERS after completion" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"

  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "content" > "$diff_file"

  run_reviewers() {
    local rd
    rd="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"
    echo "$rd"
  }
  export -f run_reviewers
  post_review_comments() { return 0; }
  export -f post_review_comments

  _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "cron"

  # AUTOPILOT_REVIEWERS should be restored to original value.
  [ "$AUTOPILOT_REVIEWERS" = "general,dry,performance,security,design" ]
}

@test "diff-reduction review: restores AUTOPILOT_REVIEWERS on error" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"

  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "content" > "$diff_file"

  run_reviewers() { return 1; }
  export -f run_reviewers

  run _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "cron"
  [ "$status" -eq "$REVIEW_ERROR" ]

  # AUTOPILOT_REVIEWERS should still be restored.
  [ "$AUTOPILOT_REVIEWERS" = "general,dry,performance,security,design" ]
}

@test "diff-reduction review: returns REVIEW_ERROR when reviewer fails" {
  _set_state "pr_open"
  write_state "$TEST_PROJECT_DIR" "pr_number" "42"
  write_state_num "$TEST_PROJECT_DIR" "current_task" 1

  local diff_file="$BATS_TEST_TMPDIR/sampled.diff"
  echo "content" > "$diff_file"

  run_reviewers() { return 1; }
  export -f run_reviewers

  run _run_diff_reduction_review "$TEST_PROJECT_DIR" "42" "$diff_file" "cron"
  [ "$status" -eq "$REVIEW_ERROR" ]
}

# --- check_diff_still_oversized ---

@test "check_diff_still_oversized: returns 0 (true) when diff still large" {
  AUTOPILOT_MAX_DIFF_BYTES=100

  gh() {
    if [[ "$1" == "pr" && "$2" == "diff" ]]; then
      python3 -c "print('x' * 200)"
    fi
  }
  export -f gh

  check_diff_still_oversized "$TEST_PROJECT_DIR" "42"
}

@test "check_diff_still_oversized: returns 1 (false) when diff under limit" {
  AUTOPILOT_MAX_DIFF_BYTES=500000

  gh() {
    if [[ "$1" == "pr" && "$2" == "diff" ]]; then
      echo "small diff"
    fi
  }
  export -f gh

  run check_diff_still_oversized "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq 1 ]
}

@test "check_diff_still_oversized: returns 2 on gh failure" {
  gh() { return 1; }
  export -f gh

  run check_diff_still_oversized "$TEST_PROJECT_DIR" "42"
  [ "$status" -eq 2 ]
}
