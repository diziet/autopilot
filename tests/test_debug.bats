#!/usr/bin/env bats

load helpers/dispatcher_setup

@test "debug pending detailed" {
  _set_state "pending"
  _set_task 1
  _mock_pending_pipeline

  # Run _handle_pending to see what happens
  local output
  output="$(_handle_pending "$TEST_PROJECT_DIR" 2>&1)" || true
  echo "# Output: $output" >&3
  echo "# Status: $(_get_status)" >&3
  echo "# State: $(cat "$TEST_PROJECT_DIR/.autopilot/state.json")" >&3
  
  # Check branch
  echo "# Branches: $(git -C "$TEST_PROJECT_DIR" branch)" >&3
  echo "# HEAD: $(git -C "$TEST_PROJECT_DIR" rev-parse HEAD 2>/dev/null)" >&3
  echo "# Log: $(git -C "$TEST_PROJECT_DIR" log --oneline -5 2>/dev/null)" >&3
  
  # Check resolve_task_dir
  local task_dir
  task_dir="$(resolve_task_dir "$TEST_PROJECT_DIR" 1)"
  echo "# task_dir: $task_dir" >&3
  
  # Check target branch resolution
  local target_branch
  target_branch="$(_resolve_checkout_target "$TEST_PROJECT_DIR")"
  echo "# target_branch: $target_branch" >&3
  
  [ "$(_get_status)" = "pr_open" ]
}
