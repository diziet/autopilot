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

@test "run_fixer uses --resume when fixer JSON has session_id and resume enabled" {
  # Create fixer JSON with session_id.
  echo '{"session_id":"prev-fixer-sess"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-2.json"

  _setup_run_fixer_mocks
  AUTOPILOT_FIXER_RESUME_SESSION="true"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 2 99)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--resume"
  echo "$content" | grep -qF "prev-fixer-sess"
}

@test "run_fixer uses --resume from coder JSON when resume enabled" {
  # Create coder JSON with session_id (no fixer JSON).
  echo '{"session_id":"coder-sess-abc"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-3.json"

  _setup_run_fixer_mocks
  AUTOPILOT_FIXER_RESUME_SESSION="true"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 3 55)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--resume"
  echo "$content" | grep -qF "coder-sess-abc"
}

@test "run_fixer uses --system-prompt on cold start" {
  # No fixer or coder JSON — cold start.
  _setup_run_fixer_mocks

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 8 77)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--system-prompt"
  ! echo "$content" | grep -qF -- "--resume"
}

@test "run_fixer cold-starts by default even when coder session ID exists" {
  # Create coder JSON with session_id.
  echo '{"session_id":"coder-sess-should-skip"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-40.json"

  _setup_run_fixer_mocks
  # Default: AUTOPILOT_FIXER_RESUME_SESSION is not set (defaults to false).
  unset AUTOPILOT_FIXER_RESUME_SESSION

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 40 77)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  # Should cold start (system-prompt), not resume.
  echo "$content" | grep -qF -- "--system-prompt"
  ! echo "$content" | grep -qF -- "--resume"
}

@test "run_fixer prompt includes commit messages from PR branch" {
  _add_git_to_test_dir

  # Create a commit on the branch so there's something to log.
  echo "change" > "$TEST_PROJECT_DIR/newfile.txt"
  git -C "$TEST_PROJECT_DIR" add newfile.txt
  git -C "$TEST_PROJECT_DIR" commit -m "feat: implement widget" --quiet

  # Set up origin/main to point at the parent commit.
  git -C "$TEST_PROJECT_DIR" update-ref refs/remotes/origin/main HEAD~1

  _setup_run_fixer_mocks

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42 "$TEST_PROJECT_DIR")" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "What Was Done (Branch Commits)"
  echo "$content" | grep -qF "feat: implement widget"
}

@test "run_fixer prompt handles empty commit log gracefully" {
  _add_git_to_test_dir

  # Point origin/main at HEAD — no divergence, so no commits to show.
  git -C "$TEST_PROJECT_DIR" update-ref refs/remotes/origin/main HEAD

  _setup_run_fixer_mocks

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42 "$TEST_PROJECT_DIR")" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  # Should not include the commit section when there are no commits.
  ! echo "$content" | grep -qF "What Was Done"
}

@test "AUTOPILOT_FIXER_RESUME_SESSION=true restores resume behavior" {
  echo '{"session_id":"fixer-sess-resume"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-41.json"

  _setup_run_fixer_mocks
  AUTOPILOT_FIXER_RESUME_SESSION="true"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 41 88)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF -- "--resume"
  echo "$content" | grep -qF "fixer-sess-resume"
  ! echo "$content" | grep -qF -- "--system-prompt"
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

  _setup_run_fixer_mocks

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 9 88)" || true
  _FIXER_TEST_OUTPUT_FILE="$output_file"

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "test_edge_case fails"
  echo "$content" | grep -qF "Diagnosis from Previous Attempt"

  # Hints file should have been consumed (deleted).
  [ ! -f "$hints_file" ]
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

# --- session resume fallback ---

@test "run_fixer falls back to cold start when resume session not found" {
  echo '{"session_id":"stale-sess-999"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-30.json"

  _setup_session_fallback_mocks "stale-sess-999" \
    '{"result":"cold start success","session_id":"new-sess-1"}'

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 30 50)" || exit_code=$?

  [ "$exit_code" -eq 0 ]

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "cold start success"

  grep -qF "Session stale-sess-999 not found" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

  rm -f "$output_file" "${output_file}.err"
}

@test "stale session JSON is cleaned up after fallback" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"stale-sess-777"}' > "${log_dir}/fixer-task-31.json"
  echo '{"session_id":"stale-coder-777"}' > "${log_dir}/coder-task-31.json"

  _setup_session_fallback_mocks "stale-sess-777" \
    '{"result":"ok","session_id":"fresh-sess"}'

  run_fixer "$TEST_PROJECT_DIR" 31 51 || true

  # Coder JSON should be deleted. Fixer JSON may be recreated by _save_fixer_output.
  [ ! -f "${log_dir}/coder-task-31.json" ]

  grep -qF "Deleted stale session files for task 31" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "retry count is not incremented for session-not-found failures" {
  echo '{"session_id":"stale-sess-888"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-32.json"

  _setup_session_fallback_mocks "stale-sess-888" \
    '{"result":"fixed","session_id":"new-sess-2"}'

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 32 52)" || exit_code=$?

  # The fixer should succeed (exit 0) — the session-not-found
  # was handled internally without consuming a retry.
  [ "$exit_code" -eq 0 ]

  # Claude was called exactly 2 times (non-auth): failed resume + cold start.
  local call_count
  call_count="$(cat "$BATS_TEST_TMPDIR/claude_call_count")"
  [ "$call_count" -eq 2 ]

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
