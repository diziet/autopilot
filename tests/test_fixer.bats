#!/usr/bin/env bats
# Tests for lib/fixer.sh — Fixer agent spawning, session resume,
# review comment fetching, diagnosis hints, and hook management.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/fixer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  TEST_HOOKS_DIR="$(mktemp -d)"

  # Source fixer.sh (which sources config, state, claude, hooks, git-ops).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
  # Clean up any function mocks.
  unset -f claude gh timeout 2>/dev/null || true
}

# --- get_repo_slug ---

@test "get_repo_slug extracts owner/repo from HTTPS URL" {
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "testowner/testrepo" ]
}

@test "get_repo_slug extracts owner/repo from SSH URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "git@github.com:myorg/myproject.git"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "myorg/myproject" ]
}

@test "get_repo_slug handles URL without .git suffix" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://github.com/owner/repo"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "get_repo_slug fails for non-github URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://gitlab.com/owner/repo.git"
  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "get_repo_slug fails for directory without git" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  run get_repo_slug "$no_git_dir"
  [ "$status" -ne 0 ]
  rm -rf "$no_git_dir"
}

# --- _read_prompt_file ---

@test "_read_prompt_file reads prompts/fix-and-merge.md" {
  local result
  result="$(_read_prompt_file "${_FIXER_PROMPTS_DIR}/fix-and-merge.md")"
  echo "$result" | grep -qF "Fixer Agent"
  echo "$result" | grep -qF "Review Comments"
}

@test "_read_prompt_file fails when prompt file missing" {
  run _read_prompt_file "$TEST_PROJECT_DIR/nonexistent/prompt.md"
  [ "$status" -eq 1 ]
}

# --- build_fixer_prompt ---

@test "build_fixer_prompt includes PR number and branch" {
  local result
  result="$(build_fixer_prompt 42 "autopilot/task-5" "Fix the bug" "owner/repo")"
  echo "$result" | grep -qF "PR #42"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_fixer_prompt includes review text" {
  local result
  result="$(build_fixer_prompt 10 "branch" "Please fix variable naming" "o/r")"
  echo "$result" | grep -qF "Please fix variable naming"
}

@test "build_fixer_prompt includes repo slug" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "myorg/myrepo")"
  echo "$result" | grep -qF "myorg/myrepo"
}

@test "build_fixer_prompt includes instructions section" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r")"
  echo "$result" | grep -qF "Instructions"
  echo "$result" | grep -qF "Do NOT merge"
}

@test "build_fixer_prompt omits hints section when empty" {
  local ctx
  ctx="$(build_fixer_context_sections "" "" "")"
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "$ctx")"
  ! echo "$result" | grep -qF "Diagnosis from Previous Attempt"
}

@test "build_fixer_prompt includes diagnosis hints when provided" {
  local hints="The merger rejected because tests fail on edge case X."
  local ctx
  ctx="$(build_fixer_context_sections "$hints" "" "")"
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "$ctx")"
  echo "$result" | grep -qF "Diagnosis from Previous Attempt"
  echo "$result" | grep -qF "tests fail on edge case X"
}

# --- consume_diagnosis_hints ---

@test "consume_diagnosis_hints reads and deletes hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-3.md"
  echo "Fix the flaky test" > "$hints_file"

  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 3)"
  echo "$result" | grep -qF "Fix the flaky test"

  # File should be deleted after consumption.
  [ ! -f "$hints_file" ]
}

@test "consume_diagnosis_hints returns empty for missing hints file" {
  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 99)"
  [ -z "$result" ]
}

@test "consume_diagnosis_hints returns empty for empty hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-7.md"
  touch "$hints_file"

  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 7)"
  [ -z "$result" ]
}

# --- _extract_session_id ---

@test "_extract_session_id extracts session_id from JSON file" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo '{"result":"done","session_id":"sess-abc123"}' > "$json_file"

  local result
  result="$(_extract_session_id "$json_file")"
  [ "$result" = "sess-abc123" ]
}

@test "_extract_session_id fails for missing file" {
  run _extract_session_id "$TEST_PROJECT_DIR/nonexistent.json"
  [ "$status" -ne 0 ]
}

@test "_extract_session_id fails for JSON without session_id" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo '{"result":"done"}' > "$json_file"

  run _extract_session_id "$json_file"
  [ "$status" -ne 0 ]
}

@test "_extract_session_id fails for invalid JSON" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo 'not valid json' > "$json_file"

  run _extract_session_id "$json_file"
  [ "$status" -ne 0 ]
}

# --- _resolve_session_id ---

@test "_resolve_session_id prefers fixer JSON over coder JSON" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"fixer-sess"}' > "${log_dir}/fixer-task-5.json"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-5.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 5)"
  [ "$result" = "fixer-sess:fixer" ]
}

@test "_resolve_session_id falls back to coder JSON" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-3.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 3)"
  [ "$result" = "coder-sess:coder" ]
}

@test "_resolve_session_id returns failure for cold start" {
  run _resolve_session_id "$TEST_PROJECT_DIR" 99
  [ "$status" -ne 0 ]
}

@test "_resolve_session_id skips fixer JSON without session_id" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"result":"done"}' > "${log_dir}/fixer-task-4.json"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-4.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 4)"
  [ "$result" = "coder-sess:coder" ]
}

@test "_resolve_session_id cold starts when both lack session_id" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"result":"done"}' > "${log_dir}/fixer-task-6.json"
  echo '{"result":"done"}' > "${log_dir}/coder-task-6.json"

  run _resolve_session_id "$TEST_PROJECT_DIR" 6
  [ "$status" -ne 0 ]
}

@test "_resolve_session_id finds coder JSON saved by _save_coder_output" {
  # Simulate what run_coder does: save output to logs/coder-task-N.json.
  source "$BATS_TEST_DIRNAME/../lib/coder.sh"

  local output_file
  output_file="$(mktemp)"
  echo '{"result":"done","session_id":"saved-coder-sess"}' > "$output_file"

  _save_coder_output "$TEST_PROJECT_DIR" 10 "$output_file"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 10)"
  [ "$result" = "saved-coder-sess:coder" ]

  rm -f "$output_file"
}

# --- _save_fixer_output ---

@test "_save_fixer_output copies output to logs dir" {
  local output_file
  output_file="$(mktemp)"
  echo '{"result":"fixed","session_id":"new-sess"}' > "$output_file"

  _save_fixer_output "$TEST_PROJECT_DIR" 5 "$output_file"

  local saved="${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-5.json"
  [ -f "$saved" ]

  local saved_content
  saved_content="$(cat "$saved")"
  echo "$saved_content" | grep -qF "new-sess"

  rm -f "$output_file"
}

@test "_save_fixer_output handles missing output file gracefully" {
  run _save_fixer_output "$TEST_PROJECT_DIR" 5 "/nonexistent/file"
  [ "$status" -eq 0 ]
}

# --- run_fixer (with mock claude and gh) ---

@test "run_fixer calls claude with review comments and returns output" {
  # Mock claude.
  claude() {
    echo '{"result":"fixes applied","session_id":"fix-sess-1"}'
  }
  export -f claude

  # Mock gh to return review comments.
  gh() { echo '[]'; }
  export -f gh

  # Mock timeout to pass through.
  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ -f "$output_file" ]

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "fixes applied"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer uses --resume when fixer JSON has session_id" {
  # Create fixer JSON with session_id.
  echo '{"session_id":"prev-fixer-sess"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-2.json"

  # Mock claude that captures args.
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude

  # Mock gh.
  gh() { echo '[]'; }
  export -f gh

  # Mock timeout.
  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 2 99)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--resume"
  echo "$content" | grep -qF "prev-fixer-sess"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer uses --resume from coder JSON when no fixer JSON" {
  # Create coder JSON with session_id (no fixer JSON).
  echo '{"session_id":"coder-sess-abc"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-3.json"

  # Mock claude.
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude

  # Mock gh.
  gh() { echo '[]'; }
  export -f gh

  # Mock timeout.
  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 3 55)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--resume"
  echo "$content" | grep -qF "coder-sess-abc"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer uses --system-prompt on cold start" {
  # No fixer or coder JSON — cold start.

  # Mock claude.
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude

  # Mock gh.
  gh() { echo '[]'; }
  export -f gh

  # Mock timeout.
  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 8 77)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--system-prompt"
  ! echo "$content" | grep -qF -- "--resume"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer saves output for future session resume" {
  claude() {
    echo '{"result":"done","session_id":"saved-sess"}'
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  run_fixer "$TEST_PROJECT_DIR" 4 33 || true

  local saved="${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-4.json"
  [ -f "$saved" ]

  local saved_content
  saved_content="$(cat "$saved")"
  echo "$saved_content" | grep -qF "saved-sess"
}

@test "run_fixer installs and removes hooks" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"

  # Mock claude that checks hooks via settings file.
  # Use eval to capture settings_file path in the function body.
  eval "claude() {
    if [ -f \"${settings_file}\" ]; then
      local count
      count=\$(jq '.hooks.stop | length' \"${settings_file}\" 2>/dev/null)
      echo \"{\\\"result\\\":\\\"hooks_count=\${count}\\\"}\"
    else
      echo '{\"result\":\"no_settings_file\"}'
    fi
  }"
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  # Mock claude should have seen hooks installed.
  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "hooks_count=2"

  # After run_fixer, hooks should be cleaned up.
  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer returns claude exit code on failure" {
  claude() {
    echo '{"result":"error"}'
    return 1
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer includes diagnosis hints in prompt" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-9.md"
  echo "The merger rejected: test_edge_case fails" > "$hints_file"

  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 9 88)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "test_edge_case fails"
  echo "$content" | grep -qF "Diagnosis from Previous Attempt"

  # Hints file should have been consumed (deleted).
  [ ! -f "$hints_file" ]

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer logs fixer prompt size metrics" {
  claude() {
    echo '{"result":"done"}'
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 5 42)" || true

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -q "METRICS: fixer prompt size" "$log_file"
  grep -qE "METRICS: fixer prompt size ~[1-9][0-9]* bytes \([1-9][0-9]* est\. tokens\)" "$log_file"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer logs to pipeline log" {
  claude() {
    echo '{"result":"done"}'
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 5 42)" || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Spawning Fixer for task 5"
  echo "$log_content" | grep -qF "Fixer completed task 5, PR #42"

  rm -f "$output_file" "${output_file}.err"
}

@test "run_fixer uses AUTOPILOT_TIMEOUT_FIXER" {
  # Need the REAL timeout command for this test.
  unset -f timeout

  local mock_dir
  mock_dir="$(mktemp -d)"

  # Mock responds instantly to auth probes (-p "echo ok"), sleeps on real runs.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "echo ok" ]]; then
    echo "ok"
    exit 0
  fi
done
sleep 30
echo '{"result":"should not reach here"}'
MOCK
  chmod +x "$mock_dir/claude"

  # gh mock as function won't be visible to timeout subprocess, use script.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  # Symlink real timeout (not the template passthrough mock) to enforce the limit.
  ln -sf /opt/homebrew/bin/timeout "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=1
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 124 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses AUTOPILOT_CODER_CONFIG_DIR" {
  claude() {
    echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
  }
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="/custom/fixer/config"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "config=/custom/fixer/config"

  rm -f "$output_file" "${output_file}.err"
}

# --- fetch_review_comments (with mock gh) ---

@test "fetch_review_comments returns empty when gh returns empty arrays" {
  gh() { echo ''; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  local result
  result="$(fetch_review_comments "$TEST_PROJECT_DIR" 42)"
  [ -z "$result" ]
}

@test "fetch_review_comments formats review sections" {
  # Mock gh to return different content for different API endpoints.
  gh() {
    case "$3" in
      */reviews) echo "review body text" ;;
      */comments) echo "inline comment text" ;;
      */issues/*) echo "issue comment text" ;;
    esac
  }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  local result
  result="$(fetch_review_comments "$TEST_PROJECT_DIR" 42)"
  echo "$result" | grep -qF "Review Comments"
  echo "$result" | grep -qF "Inline Comments"
  echo "$result" | grep -qF "Discussion"
}

@test "fetch_review_comments fails without repo slug" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  mkdir -p "$no_git_dir/.autopilot/logs"

  run fetch_review_comments "$no_git_dir" 42
  [ "$status" -ne 0 ]

  rm -rf "$no_git_dir"
}

# --- session ID parsing with colons ---

@test "session ID parsing handles colons in session ID" {
  # Verify %:* correctly strips only the last :suffix.
  local compound="sess:abc:123:fixer"
  local session_id="${compound%:*}"
  local source="${compound##*:}"

  [ "$session_id" = "sess:abc:123" ]
  [ "$source" = "fixer" ]
}

# --- _log_agent_result shared helper ---

@test "_log_agent_result logs success with extra context" {
  _log_agent_result "$TEST_PROJECT_DIR" "Fixer" 5 0 "/tmp/out" "PR #42"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Fixer completed task 5, PR #42"
}

@test "_log_agent_result logs timeout" {
  _log_agent_result "$TEST_PROJECT_DIR" "Coder" 3 124 "/tmp/out"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Coder timed out on task 3"
}

@test "_log_agent_result logs failure with exit code" {
  _log_agent_result "$TEST_PROJECT_DIR" "Fixer" 7 1 "/tmp/out" "PR #99"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Fixer failed on task 7, PR #99"
  echo "$log_content" | grep -qF "exit=1"
}
