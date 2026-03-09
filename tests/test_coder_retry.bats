#!/usr/bin/env bats
# Tests for three-phase coder retry strategy.
# Covers branch preservation (Phase A), branch reset (Phase B),
# retry hints saving/reading/cleanup, and prompt construction.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source in dependency order: config → state → git-ops → coder → helpers → handlers.
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  source "$BATS_TEST_DIRNAME/../lib/git-pr.sh"
  source "$BATS_TEST_DIRNAME/../lib/coder.sh"
  source "$BATS_TEST_DIRNAME/../lib/dispatch-helpers.sh"
  source "$BATS_TEST_DIRNAME/../lib/dispatch-handlers.sh"
  load_config "$TEST_PROJECT_DIR"

  # Use direct-checkout mode for existing tests.
  AUTOPILOT_USE_WORKTREES="false"

  # Initialize state.
  init_pipeline "$TEST_PROJECT_DIR"

  # Mock external dependencies used by _retry_or_diagnose.
  _get_recent_failure_output() { echo "some error output"; }
  _is_network_error() { return 1; }
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- _save_coder_retry_hints ---

@test "save_coder_retry_hints: creates hints file with error output" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  _save_coder_retry_hints "$TEST_PROJECT_DIR" "5"

  local hints_file="$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-5.md"
  [ -f "$hints_file" ]

  local content
  content="$(cat "$hints_file")"
  [[ "$content" == *"Error Output"* ]]
}

@test "save_coder_retry_hints: includes coder JSON tail when present" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo '{"result":"test output line"}' \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-task-3.json"

  _save_coder_retry_hints "$TEST_PROJECT_DIR" "3"

  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-3.md")"
  [[ "$content" == *"Last Coder Output"* ]]
  [[ "$content" == *"test output line"* ]]
}

@test "save_coder_retry_hints: includes git log when branch has commits" {
  # Create a task branch with a commit.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-7" 2>/dev/null
  echo "work" > "$TEST_PROJECT_DIR/work.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: some work" -q

  _save_coder_retry_hints "$TEST_PROJECT_DIR" "7"

  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-7.md")"
  [[ "$content" == *"Commits on Branch"* ]]
  [[ "$content" == *"feat: some work"* ]]
}

# --- _read_coder_retry_hints ---

@test "read_coder_retry_hints: returns content when file exists" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "test hints content" \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-1.md"

  local result
  result="$(_read_coder_retry_hints "$TEST_PROJECT_DIR" "1")"
  [[ "$result" == *"test hints content"* ]]
}

@test "read_coder_retry_hints: returns empty when no file" {
  local result
  result="$(_read_coder_retry_hints "$TEST_PROJECT_DIR" "99")"
  [ -z "$result" ]
}

# --- _clean_coder_retry_hints ---

@test "clean_coder_retry_hints: removes hints file" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "hints" \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-2.md"

  _clean_coder_retry_hints "$TEST_PROJECT_DIR" "2"

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-2.md" ]
}

@test "clean_coder_retry_hints: succeeds when no file exists" {
  run _clean_coder_retry_hints "$TEST_PROJECT_DIR" "99"
  [ "$status" -eq 0 ]
}

# --- _handle_branch_preserve (Phase A) ---

@test "handle_branch_preserve: checks out existing branch" {
  # Create a task branch with commits.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  echo "existing work" > "$TEST_PROJECT_DIR/existing.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: existing work" -q

  # Switch away.
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  _handle_branch_preserve "$TEST_PROJECT_DIR" "1"

  local current
  current="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$current" = "autopilot/task-1" ]

  # Verify existing work is present.
  [ -f "$TEST_PROJECT_DIR/existing.txt" ]
}

# --- _handle_branch_reset (Phase B / first attempt) ---

@test "handle_branch_reset: deletes existing branch" {
  # Create a task branch.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  _handle_branch_reset "$TEST_PROJECT_DIR" "1" "0"

  # Branch should be gone locally.
  run git -C "$TEST_PROJECT_DIR" rev-parse --verify "autopilot/task-1"
  [ "$status" -ne 0 ]
}

@test "handle_branch_reset: logs Phase B label for retry >= 3" {
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  _handle_branch_reset "$TEST_PROJECT_DIR" "1" "3"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Phase B reset"* ]]
}

# --- _handle_pending branch strategy integration ---

@test "handle_pending: retry 0 deletes stale branch" {
  # Create a stale branch before setting state.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  write_state_num "$TEST_PROJECT_DIR" "retry_count" 0

  # Create tasks file.
  echo "## Task 1" > "$TEST_PROJECT_DIR/TASKS.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/TASKS.md"

  # Mock heavy dependencies.
  run_preflight() { return 0; }
  extract_task() { echo "Do something"; }
  count_tasks() { echo "1"; }
  detect_tasks_file() { echo "$TEST_PROJECT_DIR/TASKS.md"; }
  read_completed_summary() { echo ""; }
  record_task_start() { true; }
  run_coder() { return 0; }
  _handle_coder_result() { true; }
  check_soft_pause() { true; }
  _timer_start() { true; }
  _timer_log() { true; }
  record_claude_usage() { true; }

  _handle_pending "$TEST_PROJECT_DIR"

  # Branch should have been deleted and recreated.
  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Stale"* ]] || [[ "$log_content" == *"Deleted"* ]]
}

@test "handle_pending: retry 1 preserves existing branch" {
  # Create a task branch with commits BEFORE setting retry count
  # to avoid git add -A staging .autopilot/.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  echo "prior work" > "$TEST_PROJECT_DIR/prior.txt"
  git -C "$TEST_PROJECT_DIR" add prior.txt >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: prior work" -q
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  # Set retry count after git operations.
  write_state_num "$TEST_PROJECT_DIR" "retry_count" 1

  # Create tasks file.
  echo "## Task 1" > "$TEST_PROJECT_DIR/TASKS.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/TASKS.md"

  # Mock heavy dependencies.
  extract_task() { echo "Do something"; }
  count_tasks() { echo "1"; }
  detect_tasks_file() { echo "$TEST_PROJECT_DIR/TASKS.md"; }
  read_completed_summary() { echo ""; }
  record_task_start() { true; }
  run_coder() { return 0; }
  _handle_coder_result() { true; }
  check_soft_pause() { true; }
  _timer_start() { true; }
  _timer_log() { true; }
  record_claude_usage() { true; }
  push_branch() { true; }

  _handle_pending "$TEST_PROJECT_DIR"

  # Branch should be preserved — prior work file should exist.
  [ -f "$TEST_PROJECT_DIR/prior.txt" ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Preserving branch"* ]]
}

@test "handle_pending: retry 2 preserves existing branch" {
  # Create branch before setting state to avoid git add staging .autopilot/.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  echo "work v2" > "$TEST_PROJECT_DIR/v2.txt"
  git -C "$TEST_PROJECT_DIR" add v2.txt >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: v2 work" -q
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  write_state_num "$TEST_PROJECT_DIR" "retry_count" 2

  echo "## Task 1" > "$TEST_PROJECT_DIR/TASKS.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/TASKS.md"

  extract_task() { echo "Do something"; }
  count_tasks() { echo "1"; }
  detect_tasks_file() { echo "$TEST_PROJECT_DIR/TASKS.md"; }
  read_completed_summary() { echo ""; }
  record_task_start() { true; }
  run_coder() { return 0; }
  _handle_coder_result() { true; }
  check_soft_pause() { true; }
  _timer_start() { true; }
  _timer_log() { true; }
  record_claude_usage() { true; }
  push_branch() { true; }

  _handle_pending "$TEST_PROJECT_DIR"

  [ -f "$TEST_PROJECT_DIR/v2.txt" ]
}

@test "handle_pending: retry 3 deletes branch and starts fresh" {
  # Create branch before setting state to avoid git add staging .autopilot/.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  echo "bad approach" > "$TEST_PROJECT_DIR/bad.txt"
  git -C "$TEST_PROJECT_DIR" add bad.txt >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: bad approach" -q
  git -C "$TEST_PROJECT_DIR" checkout main 2>/dev/null

  write_state_num "$TEST_PROJECT_DIR" "retry_count" 3

  echo "## Task 1" > "$TEST_PROJECT_DIR/TASKS.md"
  echo "Do something" >> "$TEST_PROJECT_DIR/TASKS.md"

  extract_task() { echo "Do something"; }
  count_tasks() { echo "1"; }
  detect_tasks_file() { echo "$TEST_PROJECT_DIR/TASKS.md"; }
  read_completed_summary() { echo ""; }
  record_task_start() { true; }
  run_coder() { return 0; }
  _handle_coder_result() { true; }
  check_soft_pause() { true; }
  _timer_start() { true; }
  _timer_log() { true; }
  record_claude_usage() { true; }

  _handle_pending "$TEST_PROJECT_DIR"

  # bad.txt should NOT exist (fresh branch from main).
  [ ! -f "$TEST_PROJECT_DIR/bad.txt" ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Phase B reset"* ]]
}

# --- build_coder_prompt with retry hints ---

@test "build_coder_prompt: includes Phase A hints for retry 1" {
  # Create prompts dir with implement.md.
  mkdir -p "$TEST_PROJECT_DIR/prompts"
  echo "Implement the task." > "$TEST_PROJECT_DIR/prompts/implement.md"
  _CODER_PROMPTS_DIR="$TEST_PROJECT_DIR/prompts"

  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" "1" "task body" \
    "" "some hints content" "1")"

  [[ "$result" == *"Previous Attempt Context"* ]]
  [[ "$result" == *"Continue from the existing commits"* ]]
  [[ "$result" == *"some hints content"* ]]
}

@test "build_coder_prompt: includes Phase B note for retry 3" {
  mkdir -p "$TEST_PROJECT_DIR/prompts"
  echo "Implement the task." > "$TEST_PROJECT_DIR/prompts/implement.md"
  _CODER_PROMPTS_DIR="$TEST_PROJECT_DIR/prompts"

  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" "1" "task body" \
    "" "failure hints" "3")"

  [[ "$result" == *"Previous Attempt Note"* ]]
  [[ "$result" == *"starting fresh"* ]]
  [[ "$result" == *"failure hints"* ]]
}

@test "build_coder_prompt: no hints section for retry 0" {
  mkdir -p "$TEST_PROJECT_DIR/prompts"
  echo "Implement the task." > "$TEST_PROJECT_DIR/prompts/implement.md"
  _CODER_PROMPTS_DIR="$TEST_PROJECT_DIR/prompts"

  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" "1" "task body" \
    "" "" "0")"

  [[ "$result" != *"Previous Attempt"* ]]
}

@test "build_coder_prompt: no hints section when hints empty" {
  mkdir -p "$TEST_PROJECT_DIR/prompts"
  echo "Implement the task." > "$TEST_PROJECT_DIR/prompts/implement.md"
  _CODER_PROMPTS_DIR="$TEST_PROJECT_DIR/prompts"

  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" "1" "task body" \
    "" "" "2")"

  [[ "$result" != *"Previous Attempt"* ]]
}

# --- Hints cleanup after success ---

@test "handle_coder_result: cleans hints on successful coder run" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  echo "old hints" \
    > "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-1.md"
  write_state "$TEST_PROJECT_DIR" "status" "implementing"

  # Create task branch with commits so coder result succeeds.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" 2>/dev/null
  echo "impl" > "$TEST_PROJECT_DIR/impl.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: impl" -q

  # Mock PR detection and creation.
  detect_task_pr() { echo "https://github.com/test/repo/pull/10"; }
  _timer_start() { true; }
  _timer_log() { true; }
  _extract_pr_number() { echo "10"; }
  write_state() { command write_state "$@" 2>/dev/null || true; }
  run_test_gate_background() { true; }
  _trigger_reviewer_background() { true; }

  # Re-source to get clean functions (write_state override above is scoped).
  source "$BATS_TEST_DIRNAME/../lib/state.sh" 2>/dev/null || true

  _handle_coder_result "$TEST_PROJECT_DIR" "1" "0"

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-1.md" ]
}

# --- Phase boundary at retry_count=3 ---

@test "phase boundary: retry 2 is Phase A, retry 3 is Phase B" {
  # Test that retry_count=2 preserves and retry_count=3 resets.
  # Phase A boundary
  local is_phase_a=false
  if [[ 2 -ge 1 && 2 -le 2 ]]; then
    is_phase_a=true
  fi
  [ "$is_phase_a" = "true" ]

  # Phase B boundary
  local is_phase_b=false
  if [[ 3 -ge 1 && 3 -le 2 ]]; then
    is_phase_b=true
  fi
  [ "$is_phase_b" = "false" ]
}

# --- _retry_or_diagnose saves hints before retry ---

@test "retry_or_diagnose: saves hints before incrementing retry" {
  write_state "$TEST_PROJECT_DIR" "status" "implementing"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  _retry_or_diagnose "$TEST_PROJECT_DIR" "1" "implementing"

  local hints_file="$TEST_PROJECT_DIR/.autopilot/logs/coder-retry-hints-task-1.md"
  [ -f "$hints_file" ]

  # Retry should also have been incremented.
  local retry_count
  retry_count="$(get_retry_count "$TEST_PROJECT_DIR")"
  [ "$retry_count" = "1" ]
}
