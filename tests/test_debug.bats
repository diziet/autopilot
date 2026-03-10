#!/usr/bin/env bats

load helpers/dispatcher_setup

@test "debug pending" {
  _set_state "pending"
  _set_task 1
  _mock_pending_pipeline

  dispatch_tick "$TEST_PROJECT_DIR" 2>&1 || true
  local status
  status="$(_get_status)"
  echo "# Final status: $status" >&3
  echo "# State file:" >&3
  cat "$TEST_PROJECT_DIR/.autopilot/state.json" >&3
  [ "$status" = "pr_open" ]
}
