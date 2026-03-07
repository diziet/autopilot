#!/usr/bin/env bats
# Tests for task content hash validation.
# Covers: hash stored on branch creation, hash match on unchanged tasks,
# hash mismatch logs warning.

load helpers/dispatcher_setup

# --- _compute_hash ---

@test "compute_hash: produces consistent output" {
  local hash1 hash2
  hash1="$(echo "test content" | _compute_hash)"
  hash2="$(echo "test content" | _compute_hash)"
  [ "$hash1" = "$hash2" ]
  [ -n "$hash1" ]
}

@test "compute_hash: different content produces different hash" {
  local hash1 hash2
  hash1="$(echo "content A" | _compute_hash)"
  hash2="$(echo "content B" | _compute_hash)"
  [ "$hash1" != "$hash2" ]
}

# --- _check_task_content_hash ---

@test "task hash: no warning when task content unchanged" {
  _set_state "pending"
  _set_task 1

  # Compute and store hash of task 1.
  local tasks_file
  tasks_file="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  local task_body
  task_body="$(extract_task "$tasks_file" 1)"
  local hash
  hash="$(echo "$task_body" | _compute_hash)"
  write_state "$TEST_PROJECT_DIR" "task_content_hash" "$hash"

  # Check — should NOT warn.
  _check_task_content_hash "$TEST_PROJECT_DIR" 1
  ! grep -q "Task content changed" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "task hash: warning when task content changed" {
  _set_state "pending"
  _set_task 1

  # Store a hash that doesn't match current task content.
  write_state "$TEST_PROJECT_DIR" "task_content_hash" "stale_hash_value"

  # Check — should log a warning.
  _check_task_content_hash "$TEST_PROJECT_DIR" 1
  grep -q "Task content changed since branch creation" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "task hash: no-op when no stored hash" {
  _set_state "pending"
  _set_task 1

  # Don't write any hash. Should silently return.
  _check_task_content_hash "$TEST_PROJECT_DIR" 1
  ! grep -q "Task content changed" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "task hash: stored during _handle_pending branch creation" {
  _set_state "pending"
  _set_task 1

  local test_dir="$TEST_PROJECT_DIR"
  run_preflight() { return 0; }
  run_coder() {
    echo "change" >> "$test_dir/testfile.txt"
    git -C "$test_dir" add -A >/dev/null 2>&1
    git -C "$test_dir" commit -m "feat: implement" -q
    return 0
  }
  push_branch() { return 0; }
  generate_pr_body() { echo "PR body"; }
  create_task_pr() { echo "https://github.com/testowner/testrepo/pull/42"; }
  detect_task_pr() { return 1; }
  run_test_gate_background() { echo "/tmp/test_gate_result"; }
  _trigger_reviewer_background() { return 0; }
  export -f run_preflight run_coder push_branch generate_pr_body
  export -f create_task_pr detect_task_pr run_test_gate_background
  export -f _trigger_reviewer_background

  _handle_pending "$TEST_PROJECT_DIR"

  # Verify hash was stored in state.
  local stored_hash
  stored_hash="$(read_state "$TEST_PROJECT_DIR" "task_content_hash")"
  [ -n "$stored_hash" ]

  # Verify hash matches the actual task content (use echo to normalize).
  local tasks_file
  tasks_file="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  local task_body
  task_body="$(extract_task "$tasks_file" 1)"
  local expected_hash
  expected_hash="$(echo "$task_body" | _compute_hash)"
  [ "$stored_hash" = "$expected_hash" ]
}

@test "task hash: mismatch detected when task modified after branch" {
  _set_state "pending"
  _set_task 1

  # Store hash for original task content.
  local tasks_file
  tasks_file="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  local original_hash
  original_hash="$(extract_task "$tasks_file" 1 | _compute_hash)"
  write_state "$TEST_PROJECT_DIR" "task_content_hash" "$original_hash"

  # Modify the tasks file to change task 1 content.
  sed -i '' 's/Do thing 1/Do something completely different/' "$tasks_file"

  # Now check — should detect the change and warn.
  _check_task_content_hash "$TEST_PROJECT_DIR" 1
  grep -q "task may have been renumbered" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}
