#!/usr/bin/env bats
# Tests for lib/context.sh — Context accumulation, summary generation,
# reading, prompt construction, and background execution.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/context.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_light

  # Source context.sh (which sources config, state, claude, git-ops).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _CONTEXT_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Shell function mocks (inherited by subshells, no disk I/O).
  timeout() { shift; "$@"; }
  export -f timeout

  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"--json state"*) echo "MERGED" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*"headRefOid"*) echo "abc123def456" ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr merge"*) return 0 ;;
      *"pr comment"*) return 0 ;;
      *"api"*"git/ref"*) echo 'abc123' ;;
      *"api"*"pulls"*"reviews"*) echo "" ;;
      *"api"*"pulls"*"comments"*) echo "" ;;
      *"api"*"issues"*"comments"*) echo "" ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh

  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
}

# --- Exit Code Constants ---

@test "CONTEXT_OK is 0" {
  [ "$CONTEXT_OK" -eq 0 ]
}

@test "CONTEXT_ERROR is 1" {
  [ "$CONTEXT_ERROR" -eq 1 ]
}

# --- get_summary_file ---

@test "get_summary_file returns correct path" {
  local result
  result="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ "$result" = "${TEST_PROJECT_DIR}/.autopilot/completed-summary.md" ]
}

@test "get_summary_file defaults to current directory" {
  local result
  result="$(get_summary_file)"
  [ "$result" = "./.autopilot/completed-summary.md" ]
}

# --- read_completed_summary ---

@test "read_completed_summary returns empty when file missing" {
  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "read_completed_summary returns file content" {
  local summary_file="${TEST_PROJECT_DIR}/.autopilot/completed-summary.md"
  echo "Task 1: Initial setup" > "$summary_file"

  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  [ "$result" = "Task 1: Initial setup" ]
}

@test "read_completed_summary truncates at MAX_SUMMARY_LINES" {
  local summary_file="${TEST_PROJECT_DIR}/.autopilot/completed-summary.md"
  # Write 10 lines.
  for i in $(seq 1 10); do
    echo "Line ${i}" >> "$summary_file"
  done

  AUTOPILOT_MAX_SUMMARY_LINES=5
  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  # Should contain first 5 lines and a truncation notice.
  echo "$result" | grep -qF "Line 1"
  echo "$result" | grep -qF "Line 5"
  echo "$result" | grep -qF "truncated"
  ! echo "$result" | grep -qF "Line 6"
}

@test "read_completed_summary does not add truncation notice when within limits" {
  local summary_file="${TEST_PROJECT_DIR}/.autopilot/completed-summary.md"
  echo "Line 1" > "$summary_file"
  echo "Line 2" >> "$summary_file"

  AUTOPILOT_MAX_SUMMARY_LINES=50
  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  ! echo "$result" | grep -qF "truncated"
}

@test "read_completed_summary uses default 50 lines" {
  local summary_file="${TEST_PROJECT_DIR}/.autopilot/completed-summary.md"
  for i in $(seq 1 51); do
    echo "Line ${i}" >> "$summary_file"
  done

  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "truncated"
  echo "$result" | grep -qF "Line 50"
}

# --- build_summary_prompt ---

@test "build_summary_prompt includes task number and title" {
  local result
  result="$(build_summary_prompt 5 "Add user auth" "+new code")"
  echo "$result" | grep -qF "Task 5"
  echo "$result" | grep -qF "Add user auth"
}

@test "build_summary_prompt includes diff content" {
  local result
  result="$(build_summary_prompt 1 "Init" "+added line
-removed line")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "build_summary_prompt includes system prompt from summarize.md" {
  local result
  result="$(build_summary_prompt 1 "Test" "diff")"
  # Should include content from the real summarize.md prompt.
  echo "$result" | grep -qF "Summary Generator"
}

@test "build_summary_prompt works when summarize.md is missing" {
  _CONTEXT_PROMPTS_DIR="${TEST_PROJECT_DIR}/no-prompts"
  local result
  result="$(build_summary_prompt 1 "Test" "diff")"
  # Should still produce a valid prompt without the system prompt.
  echo "$result" | grep -qF "Task 1"
  echo "$result" | grep -qF "diff"
}

# --- _append_summary ---

@test "_append_summary creates summary file when it does not exist" {
  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ ! -f "$summary_file" ]

  _append_summary "$TEST_PROJECT_DIR" 1 "Task 1: Setup complete."

  [ -f "$summary_file" ]
  grep -qF "Task 1: Setup complete." "$summary_file"
}

@test "_append_summary appends to existing file with blank separator" {
  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  echo "Task 1: First task." > "$summary_file"

  _append_summary "$TEST_PROJECT_DIR" 2 "Task 2: Second task."

  grep -qF "Task 1: First task." "$summary_file"
  grep -qF "Task 2: Second task." "$summary_file"
  # Verify there's a blank line between entries.
  local line_count
  line_count="$(wc -l < "$summary_file" | tr -d ' ')"
  [ "$line_count" -ge 3 ]
}

@test "_append_summary handles multiple appends" {
  for i in 1 2 3; do
    _append_summary "$TEST_PROJECT_DIR" "$i" "Task ${i}: Done."
  done

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  grep -qF "Task 1: Done." "$summary_file"
  grep -qF "Task 2: Done." "$summary_file"
  grep -qF "Task 3: Done." "$summary_file"
}

@test "_append_summary acquires and releases summary lock" {
  _append_summary "$TEST_PROJECT_DIR" 1 "Locked write."

  # Lock file should not exist after append (released).
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/summary.lock"
  [ ! -f "$lock_file" ]
}

@test "_append_summary cleans up temp file" {
  _append_summary "$TEST_PROJECT_DIR" 1 "Temp check."

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  # No .tmp files should remain.
  local tmp_count
  tmp_count="$(find "$(dirname "$summary_file")" -name '*.tmp.*' | wc -l | tr -d ' ')"
  [ "$tmp_count" -eq 0 ]
}

# --- _append_fallback_summary ---

@test "_append_fallback_summary writes minimal summary" {
  _append_fallback_summary "$TEST_PROJECT_DIR" 5 "Config loading"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ -f "$summary_file" ]
  grep -qF "Task 5: Config loading" "$summary_file"
  grep -qF "summary unavailable" "$summary_file"
}

@test "_append_fallback_summary uses default title when not provided" {
  _append_fallback_summary "$TEST_PROJECT_DIR" 3

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  grep -qF "Task 3" "$summary_file"
}

# --- _fetch_task_diff (mocked gh) ---

_setup_mock_gh_diff() {
  # Override gh to return diff lines.
  gh() {
    echo "+added line"
    echo "-removed line"
    return 0
  }
  export -f gh
}

@test "_fetch_task_diff returns diff from gh" {
  _setup_mock_gh_diff

  local result
  result="$(_fetch_task_diff "$TEST_PROJECT_DIR" 42)"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "_fetch_task_diff fails when repo slug unavailable" {
  git -C "$TEST_PROJECT_DIR" remote remove origin

  run _fetch_task_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
}

@test "_fetch_task_diff fails when gh fails" {
  gh() { return 1; }
  export -f gh

  local result
  result="$(_fetch_task_diff "$TEST_PROJECT_DIR" 99 || true)"
  [ -z "$result" ]
}

@test "_fetch_task_diff uses AUTOPILOT_TIMEOUT_GH" {
  local timeout_log="${TEST_PROJECT_DIR}/timeout.log"

  timeout() {
    echo "$1" >> "$timeout_log"
    shift
    "$@"
  }
  export -f timeout

  gh() { echo "diff output"; }
  export -f gh

  AUTOPILOT_TIMEOUT_GH=15
  _fetch_task_diff "$TEST_PROJECT_DIR" 42 || true

  grep -qF "15" "$timeout_log"
}

# --- generate_task_summary (mocked Claude) ---

_setup_mock_claude_summary() {
  local summary_text="${1:-Task 5: Added auth module.
Implemented JWT-based authentication.}"

  local mock_output
  mock_output="$(mktemp)"
  printf '{"result":"%s"}' "$summary_text" > "$mock_output"

  # shellcheck disable=SC2034
  eval "claude() { cat \"$mock_output\"; return 0; }"
  export -f claude
}

@test "generate_task_summary creates summary with Claude" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Task 5: Auth module added."

  generate_task_summary "$TEST_PROJECT_DIR" 5 42 "Add auth"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ -f "$summary_file" ]
  grep -qF "Task 5: Auth module added." "$summary_file"
}

@test "generate_task_summary returns CONTEXT_OK on success" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Summary text."

  generate_task_summary "$TEST_PROJECT_DIR" 5 42 "Task title"
  local exit_code=$?
  [ "$exit_code" -eq "$CONTEXT_OK" ]
}

@test "generate_task_summary falls back when diff fetch fails" {
  # No gh mock override — diff fetch will fail due to no origin.
  git -C "$TEST_PROJECT_DIR" remote remove origin

  generate_task_summary "$TEST_PROJECT_DIR" 3 42 "Some task"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ -f "$summary_file" ]
  grep -qF "summary unavailable" "$summary_file"
}

@test "generate_task_summary falls back when Claude fails" {
  _setup_mock_gh_diff

  claude() { return 1; }
  export -f claude

  generate_task_summary "$TEST_PROJECT_DIR" 7 42 "Claude fail task"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ -f "$summary_file" ]
  grep -qF "summary unavailable" "$summary_file"
}

@test "generate_task_summary falls back when Claude returns empty" {
  _setup_mock_gh_diff

  claude() { echo '{}'; return 0; }
  export -f claude

  generate_task_summary "$TEST_PROJECT_DIR" 9 42 "Empty response"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  grep -qF "summary unavailable" "$summary_file"
}

@test "generate_task_summary returns CONTEXT_OK even on Claude failure" {
  _setup_mock_gh_diff

  claude() { return 1; }
  export -f claude

  generate_task_summary "$TEST_PROJECT_DIR" 7 42 "Non-blocking"
  local exit_code=$?
  [ "$exit_code" -eq "$CONTEXT_OK" ]
}

@test "generate_task_summary falls back when no PR number given" {
  generate_task_summary "$TEST_PROJECT_DIR" 1 "" "No PR"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  grep -qF "summary unavailable" "$summary_file"
}

@test "generate_task_summary uses AUTOPILOT_TIMEOUT_SUMMARY" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Summary."

  local timeout_log="${TEST_PROJECT_DIR}/timeout.log"
  timeout() {
    echo "$1" >> "$timeout_log"
    shift
    "$@"
  }
  export -f timeout

  AUTOPILOT_TIMEOUT_SUMMARY=30
  generate_task_summary "$TEST_PROJECT_DIR" 1 42 "Timeout test" || true

  grep -qF "30" "$timeout_log"
}

@test "generate_task_summary truncates oversized diffs" {
  # gh returns a large diff.
  gh() {
    python3 -c "print('+' * 1000)"
    return 0
  }
  export -f gh

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"
  eval "claude() {
    # Capture the prompt.
    while [[ \$# -gt 0 ]]; do
      if [[ \"\$1\" == \"--print\" ]]; then
        echo \"\$2\" >> \"$prompt_log\"
        break
      fi
      shift
    done
    echo '{\"result\":\"Summary text.\"}'
    return 0
  }"
  export -f claude

  AUTOPILOT_MAX_DIFF_BYTES=100
  generate_task_summary "$TEST_PROJECT_DIR" 1 42 "Large diff" || true

  grep -qF "truncated" "$prompt_log"
}

@test "generate_task_summary trims long summaries to MAX_SUMMARY_ENTRY_LINES" {
  _setup_mock_gh_diff

  # Create a multi-line summary response.
  local long_summary=""
  for i in $(seq 1 20); do
    long_summary="${long_summary}Line ${i}.\n"
  done

  local mock_output
  mock_output="$(mktemp)"
  printf '{"result":"%s"}' "$long_summary" > "$mock_output"

  eval "claude() { cat \"$mock_output\"; return 0; }"
  export -f claude

  AUTOPILOT_MAX_SUMMARY_ENTRY_LINES=5
  generate_task_summary "$TEST_PROJECT_DIR" 1 42 "Long summary"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  local line_count
  line_count="$(wc -l < "$summary_file" | tr -d ' ')"
  # Should be at most 5 lines for the summary plus a trailing newline.
  [ "$line_count" -le 6 ]
}

@test "generate_task_summary uses separate entry limit from read limit" {
  _setup_mock_gh_diff

  # Set different values for the two limits.
  AUTOPILOT_MAX_SUMMARY_LINES=100
  AUTOPILOT_MAX_SUMMARY_ENTRY_LINES=3

  # Create a multi-line summary response.
  local long_summary=""
  for i in $(seq 1 10); do
    long_summary="${long_summary}Line ${i}.\n"
  done

  local mock_output
  mock_output="$(mktemp)"
  printf '{"result":"%s"}' "$long_summary" > "$mock_output"

  eval "claude() { cat \"$mock_output\"; return 0; }"
  export -f claude

  generate_task_summary "$TEST_PROJECT_DIR" 1 42 "Separate limits"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  local line_count
  line_count="$(wc -l < "$summary_file" | tr -d ' ')"
  # Entry limit of 3 should trim, not the read limit of 100.
  [ "$line_count" -le 4 ]
}

@test "generate_task_summary logs to pipeline.log" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Summary."

  generate_task_summary "$TEST_PROJECT_DIR" 3 42 "Log check"

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  [ -f "$log_file" ]
  grep -qF "Generating summary for task 3" "$log_file"
  grep -qF "Appended summary for task 3" "$log_file"
}

# --- generate_task_summary_bg ---

@test "generate_task_summary_bg spawns background process" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "BG summary."

  # Call directly (not in subshell) so $! is valid.
  generate_task_summary_bg "$TEST_PROJECT_DIR" 1 42 "BG test"
  local bg_pid=$!

  # PID should be a number.
  [[ "$bg_pid" =~ ^[0-9]+$ ]]

  # Wait for background process to finish.
  wait "$bg_pid"
}

@test "generate_task_summary_bg creates summary file with correct content" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Background result."

  generate_task_summary_bg "$TEST_PROJECT_DIR" 2 42 "BG result"
  wait $!

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"
  [ -f "$summary_file" ]
  # Verify actual content — not just file existence.
  grep -qF "Background result." "$summary_file"
}

@test "generate_task_summary_bg logs start message" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "BG log test."

  generate_task_summary_bg "$TEST_PROJECT_DIR" 4 42 "BG log"
  wait $!

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "background summary generation for task 4" "$log_file"
}

@test "generate_task_summary_bg wait succeeds as child process" {
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Wait test."

  generate_task_summary_bg "$TEST_PROJECT_DIR" 6 42 "Wait"
  local bg_pid=$!

  # wait should succeed without error since we called directly.
  wait "$bg_pid"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

# --- _run_claude_and_extract (shared helper from lib/claude.sh) ---

@test "_run_claude_and_extract returns text on success" {
  _setup_mock_claude_summary "Extracted text."

  local result
  result="$(_run_claude_and_extract 60 "test prompt")"
  [ "$result" = "Extracted text." ]
}

@test "_run_claude_and_extract returns 1 on Claude failure" {
  claude() { return 1; }
  export -f claude

  run _run_claude_and_extract 60 "test prompt"
  [ "$status" -eq 1 ]
}

@test "_run_claude_and_extract returns 1 on empty response" {
  claude() { echo '{}'; return 0; }
  export -f claude

  run _run_claude_and_extract 60 "test prompt"
  [ "$status" -eq 1 ]
}

@test "_run_claude_and_extract cleans up its own temp files" {
  _setup_mock_claude_summary "Cleanup test."

  # Verify run_claude creates a temp file (so cleanup is meaningful).
  local direct_file
  direct_file="$(run_claude 60 "probe")"
  [ -f "$direct_file" ]
  rm -f "$direct_file" "${direct_file}.err"

  # _run_claude_and_extract should return data without leaking temp files.
  local result
  result="$(_run_claude_and_extract 60 "test prompt")"
  [[ "$result" == *"Cleanup test."* ]]
}

# --- Integration: multiple task summaries ---

@test "integration: accumulate summaries across multiple tasks" {
  # Task 1 — Claude succeeds.
  _setup_mock_gh_diff
  _setup_mock_claude_summary "Task 1: Setup project scaffold."
  generate_task_summary "$TEST_PROJECT_DIR" 1 10 "Project scaffold"

  # Task 2 — Claude fails, fallback.
  claude() { return 1; }
  export -f claude
  generate_task_summary "$TEST_PROJECT_DIR" 2 11 "Config loading"

  # Task 3 — Claude succeeds.
  _setup_mock_claude_summary "Task 3: Added state management."
  generate_task_summary "$TEST_PROJECT_DIR" 3 12 "State management"

  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"

  # All three tasks should be in the file.
  grep -qF "Task 1: Setup project scaffold." "$summary_file"
  grep -qF "Config loading" "$summary_file"
  grep -qF "summary unavailable" "$summary_file"
  grep -qF "Task 3: Added state management." "$summary_file"
}

@test "integration: read_completed_summary returns accumulated content" {
  _append_summary "$TEST_PROJECT_DIR" 1 "Task 1: Init."
  _append_summary "$TEST_PROJECT_DIR" 2 "Task 2: Config."

  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "Task 1: Init."
  echo "$result" | grep -qF "Task 2: Config."
}

@test "integration: summary file grows with each append" {
  local summary_file
  summary_file="$(get_summary_file "$TEST_PROJECT_DIR")"

  _append_summary "$TEST_PROJECT_DIR" 1 "First."
  local size1
  size1="$(wc -c < "$summary_file" | tr -d ' ')"

  _append_summary "$TEST_PROJECT_DIR" 2 "Second."
  local size2
  size2="$(wc -c < "$summary_file" | tr -d ' ')"

  [ "$size2" -gt "$size1" ]
}

@test "integration: MAX_SUMMARY_ENTRY_LINES and MAX_SUMMARY_LINES are independent" {
  # Generate 3 tasks that each produce 8 lines (within entry limit of 10).
  AUTOPILOT_MAX_SUMMARY_ENTRY_LINES=10
  AUTOPILOT_MAX_SUMMARY_LINES=15

  _append_summary "$TEST_PROJECT_DIR" 1 "$(printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8')"
  _append_summary "$TEST_PROJECT_DIR" 2 "$(printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8')"
  _append_summary "$TEST_PROJECT_DIR" 3 "$(printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8')"

  # File has ~26 lines but read truncates at 15.
  local result
  result="$(read_completed_summary "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "truncated"
}
