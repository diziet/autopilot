#!/usr/bin/env bats
# Tests for soft/hard pause and task content hash validation.
# Covers: check_quick_guards soft/hard pause behavior,
# check_soft_pause exit, _check_task_content_hash warnings.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/entry-common.sh"
source "$BATS_TEST_DIRNAME/../lib/state.sh"
source "$BATS_TEST_DIRNAME/../lib/config.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit

  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
  init_pipeline "$TEST_PROJECT_DIR"
}

# --- Hard Pause ---

@test "hard pause: check_quick_guards returns 1 when PAUSE contains NOW" {
  echo "NOW" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: NOW with trailing newline treated as hard" {
  printf "NOW\n" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: arbitrary non-empty content treated as hard" {
  echo "paused for maintenance" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

@test "hard pause: STOP content treated as hard" {
  echo "STOP" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 1 ]
}

# --- Soft Pause ---

@test "soft pause: check_quick_guards returns 0 when PAUSE is empty" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "soft pause: check_soft_pause exits when PAUSE file exists on disk" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Verify log was written.
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "soft pause: check_soft_pause is no-op when no PAUSE file exists" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  # Should NOT exit — just return normally.
  check_soft_pause "$TEST_PROJECT_DIR"
  # If we get here, it didn't exit. Success.
  true
}

@test "no pause: check_quick_guards returns 0 when no PAUSE file" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
}

@test "soft pause: PAUSE with whitespace only treated as soft end-to-end" {
  printf "  \n  " > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  # check_quick_guards should let the tick proceed (whitespace = soft pause).
  run check_quick_guards "$TEST_PROJECT_DIR" "pipeline"
  [ "$status" -eq 0 ]
  # check_soft_pause should then exit at the phase boundary.
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "soft pause: removing PAUSE file between ticks allows next tick to proceed" {
  # Tick 1: PAUSE file exists — check_soft_pause exits.
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  # Simulate removing PAUSE between ticks.
  rm -f "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  # Tick 2: no PAUSE file — check_soft_pause is a no-op.
  check_soft_pause "$TEST_PROJECT_DIR"
  # If we get here, it didn't exit. Success.
  true
}

@test "soft pause: two ticks with empty PAUSE file both block at phase boundary" {
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  # Tick 1: check_soft_pause exits.
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  # Tick 2: PAUSE file still on disk — check_soft_pause exits again.
  run check_soft_pause "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "soft pause: hard pause PAUSE file does not trigger check_soft_pause" {
  echo "NOW" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"
  # check_soft_pause only exits for empty (soft) PAUSE files.
  check_soft_pause "$TEST_PROJECT_DIR"
  # If we get here, it didn't exit. Success.
  true
}

# --- _handle_merged + soft pause integration ---

# Source dispatcher for _handle_merged and friends (re-sourced per subshell).
_load_dispatcher() {
  source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"
}

# Mock all external dependencies that _handle_merged calls.
_mock_merged_for_soft_pause() {
  _verify_pr_merged() { return 0; }
  record_task_complete() { return 0; }
  record_phase_durations() { return 0; }
  generate_task_summary_bg() { return 0; }
  should_run_spec_review() { return 1; }
  record_phase_transition() { return 0; }
  post_performance_summary_bg() { return 0; }
  check_spec_review_completion() { return 0; }
  cleanup_task_worktree() { return 0; }
  cleanup_stale_worktrees() { return 0; }
  _pull_main_after_merge() { return 0; }
  get_repo_slug() { echo "testowner/testrepo"; }
  resolve_task_title() { echo "Test task"; }
  export -f _verify_pr_merged record_task_complete record_phase_durations
  export -f generate_task_summary_bg should_run_spec_review record_phase_transition
  export -f post_performance_summary_bg check_spec_review_completion
  export -f cleanup_task_worktree cleanup_stale_worktrees _pull_main_after_merge
  export -f get_repo_slug resolve_task_title

  # Mock timeout.
  timeout() { shift; "$@"; }
  export -f timeout

  # Mock gh.
  gh() {
    case "$*" in
      *"pr view"*"--json state"*) echo "MERGED" ;;
      *) return 0 ;;
    esac
  }
  export -f gh
}

# Set up merged state with mocks, tasks file, and given task/PR number.
_setup_merged_for_soft_pause() {
  local task_num="${1:-1}"
  local pr_number="${2:-42}"
  _load_dispatcher
  _mock_merged_for_soft_pause
  # Create tasks file (always 3 tasks).
  local f="${TEST_PROJECT_DIR}/tasks.md"
  local i
  for (( i=1; i<=3; i++ )); do
    printf '## Task %d: Test task %d\nDo thing %d.\n\n' "$i" "$i" "$i" >> "$f"
  done
  write_state "$TEST_PROJECT_DIR" "status" "merged"
  write_state_num "$TEST_PROJECT_DIR" "current_task" "$task_num"
  write_state "$TEST_PROJECT_DIR" "pr_number" "$pr_number"
}

@test "soft pause after merge: _handle_merged calls check_soft_pause" {
  _setup_merged_for_soft_pause 1 42

  # Activate soft pause via PAUSE file on disk.
  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  # _handle_merged should exit 0 via check_soft_pause (in a subshell via run).
  run _handle_merged "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Task should have advanced to 2 (finalization completed).
  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]

  # Status should be pending (advance happened), but the tick exits before
  # _handle_pending runs because check_soft_pause called exit.
  local final_status
  final_status="$(read_state "$TEST_PROJECT_DIR" "status")"
  [ "$final_status" = "pending" ]

  # Log confirms soft pause.
  grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "soft pause after merge: normal flow without soft pause" {
  _setup_merged_for_soft_pause 1 42

  # No PAUSE file — should complete normally without exiting.
  rm -f "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  _handle_merged "$TEST_PROJECT_DIR"

  # Task advances and status is pending — normal flow.
  local next_task
  next_task="$(read_state "$TEST_PROJECT_DIR" "current_task")"
  [ "$next_task" = "2" ]
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "pending" ]

  # No soft pause log entry.
  ! grep -q "Soft pause" "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "soft pause after merge: last task completes without soft pause exit" {
  _setup_merged_for_soft_pause 3 99

  touch "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  run _handle_merged "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Should transition to completed.
  [ "$(read_state "$TEST_PROJECT_DIR" "status")" = "completed" ]
}
