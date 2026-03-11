#!/usr/bin/env bats
# Tests for fixer runtime — run_fixer invocation, session resume,
# hooks, timeouts, fetch_review_comments, and shared helpers.
# Split from test_fixer.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/fixer_setup

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
  echo "$content" | grep -qF "hooks_count=3"

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

  local mock_dir="$BATS_TEST_TMPDIR/mock_dir"
  mkdir -p "$mock_dir"

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

  # Use a real directory so health check passes.
  local custom_config="$BATS_TEST_TMPDIR/custom_fixer_config"
  mkdir -p "$custom_config"

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$custom_config"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "config=$custom_config"

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
  get_repo_slug() { return 1; }
  export -f get_repo_slug

  run fetch_review_comments "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
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
