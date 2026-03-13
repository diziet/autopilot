#!/usr/bin/env bats
# Tests for fixer diagnostics: health check, stderr preservation,
# post-spawn logging, and empty-output retry backoff.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/fixer_setup

# --- _fixer_health_check ---

@test "health check rejects empty prompt" {
  run _fixer_health_check "$TEST_PROJECT_DIR" "" "/some/config"
  [ "$status" -eq 1 ]

  grep -qF "Fixer prompt is empty" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "health check rejects missing config dir" {
  run _fixer_health_check "$TEST_PROJECT_DIR" "some prompt" "/nonexistent/dir"
  [ "$status" -eq 1 ]

  grep -qF "Fixer config dir does not exist" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "health check passes with valid prompt and no config dir" {
  run _fixer_health_check "$TEST_PROJECT_DIR" "some prompt" ""
  [ "$status" -eq 0 ]
}

@test "health check rejects whitespace-only prompt" {
  run _fixer_health_check "$TEST_PROJECT_DIR" "   " "/some/config"
  [ "$status" -eq 1 ]

  grep -qF "Fixer prompt is empty" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "health check passes with valid prompt and existing config dir" {
  run _fixer_health_check "$TEST_PROJECT_DIR" "some prompt" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

# --- _log_fixer_diagnostics ---

@test "diagnostics logs exit code and output size" {
  local output_file="$BATS_TEST_TMPDIR/fixer-output.json"
  echo '{"result":"done"}' > "$output_file"

  _log_fixer_diagnostics "$TEST_PROJECT_DIR" 5 0 "$output_file"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -qF "METRICS: fixer result task=5 exit=0" "$log_file"
  grep -qF "valid_json=true" "$log_file"

}

@test "diagnostics reports invalid JSON" {
  local output_file="$BATS_TEST_TMPDIR/fixer-output.json"
  echo "not json" > "$output_file"

  _log_fixer_diagnostics "$TEST_PROJECT_DIR" 3 1 "$output_file"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -qF "valid_json=false" "$log_file"

}

@test "diagnostics handles missing output file" {
  _log_fixer_diagnostics "$TEST_PROJECT_DIR" 7 124 "/nonexistent/file"

  local log_file="$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
  grep -qF "output_bytes=0" "$log_file"
  grep -qF "valid_json=false" "$log_file"
}

# --- _preserve_fixer_stderr ---

@test "stderr preserved when output is empty" {
  local output_file="$BATS_TEST_TMPDIR/fixer-out"
  touch "$output_file"
  echo "Claude CLI error: auth failed" > "${output_file}.err"

  _preserve_fixer_stderr "$TEST_PROJECT_DIR" 9 "$output_file"

  local preserved="$TEST_PROJECT_DIR/.autopilot/logs/fixer-task-9-stderr.log"
  [ -f "$preserved" ]
  grep -qF "auth failed" "$preserved"

  # Warning should be logged.
  grep -qF "stderr preserved to fixer-task-9-stderr.log" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"

}

@test "stderr not preserved when output has content" {
  local output_file="$BATS_TEST_TMPDIR/fixer-out"
  echo '{"result":"ok"}' > "$output_file"
  echo "some stderr" > "${output_file}.err"

  _preserve_fixer_stderr "$TEST_PROJECT_DIR" 10 "$output_file"

  local preserved="$TEST_PROJECT_DIR/.autopilot/logs/fixer-task-10-stderr.log"
  [ ! -f "$preserved" ]

}

@test "stderr preservation is no-op when stderr file missing" {
  local output_file="$BATS_TEST_TMPDIR/fixer-out"
  touch "$output_file"
  # No .err file exists.

  run _preserve_fixer_stderr "$TEST_PROJECT_DIR" 11 "$output_file"
  [ "$status" -eq 0 ]

}

# --- _fixer_empty_output_backoff ---

@test "backoff applied when output is empty" {
  local output_file="$BATS_TEST_TMPDIR/fixer-out"
  touch "$output_file"

  # Override sleep to avoid actual delay in tests.
  sleep() { :; }
  export -f sleep

  _fixer_empty_output_backoff "$TEST_PROJECT_DIR" "$output_file" 1
  local rc=$?
  [ "$rc" -eq 0 ]

  grep -qF "Fixer empty output" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "backoff not applied when output has content" {
  local output_file="$BATS_TEST_TMPDIR/fixer-out"
  echo '{"result":"ok"}' > "$output_file"

  _fixer_empty_output_backoff "$TEST_PROJECT_DIR" "$output_file" 1
  local rc=$?
  [ "$rc" -eq 0 ]
}

# --- _check_session_not_found ---

@test "check_session_not_found detects missing session in stderr" {
  local stderr_file="$BATS_TEST_TMPDIR/claude.err"
  echo "Error: No conversation found with session ID: abc-123" > "$stderr_file"

  run _check_session_not_found "$stderr_file"
  [ "$status" -eq 0 ]
}

@test "check_session_not_found returns 1 for unrelated errors" {
  local stderr_file="$BATS_TEST_TMPDIR/claude.err"
  echo "Error: API rate limit exceeded" > "$stderr_file"

  run _check_session_not_found "$stderr_file"
  [ "$status" -eq 1 ]
}

@test "check_session_not_found returns 1 when stderr file missing" {
  run _check_session_not_found "/nonexistent/file"
  [ "$status" -eq 1 ]
}

# --- _delete_stale_session_files ---

@test "delete_stale_session_files removes fixer and coder JSON" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"stale-1"}' > "${log_dir}/fixer-task-20.json"
  echo '{"session_id":"stale-2"}' > "${log_dir}/coder-task-20.json"

  _delete_stale_session_files "$TEST_PROJECT_DIR" 20

  [ ! -f "${log_dir}/fixer-task-20.json" ]
  [ ! -f "${log_dir}/coder-task-20.json" ]
  grep -qF "Deleted stale session files for task 20" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}

@test "delete_stale_session_files is safe when files don't exist" {
  run _delete_stale_session_files "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 0 ]
}

# --- run_fixer integration: empty prompt caught ---

@test "run_fixer rejects empty prompt before spawn" {
  # Mock everything to return empty, creating an empty prompt scenario.
  # Override build_fixer_prompt to return empty.
  build_fixer_prompt() { echo ""; }
  export -f build_fixer_prompt

  # Mock gh and claude.
  gh() { echo '[]'; }
  claude() { echo '{"result":"done"}'; }
  timeout() { shift; "$@"; }
  export -f gh claude timeout

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  # build_fixer_prompt returning empty makes user_prompt empty,
  # which should be caught by health check.
  local exit_code=0
  run_fixer "$TEST_PROJECT_DIR" 1 42 || exit_code=$?

  [ "$exit_code" -eq 1 ]
  grep -qF "Fixer prompt is empty" \
    "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log"
}
